// AI 语音助手成员(userId 前缀 u_ai_)不算人:验证专注计时 / 大厅人数 / 推送 / 敲门 / E2EE 转写中继都把它排除,
// 而房间成员列表(room 视图)仍包含它(客户端要画它的座位)。
// 纪律同其它集成测试:不 import 服务端代码,只看线上收发与磁盘。
// 用法:node test/ai_members.mjs     (DEBUG=1 显示服务端 stderr)

import http2 from 'node:http2';
import crypto, { randomBytes, createCipheriv } from 'node:crypto';
import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  wait, makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v1Auth, v2Auth, ownerReply,
} from './lib/harness.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = 18975;
const GLOBAL_PASS = 'aim-global-' + randomBytes(4).toString('hex');
const PASSCODE = 'aim-pass-' + randomBytes(4).toString('hex');
// u_ai_* 是保留前缀:只有带 supervisor 圈级凭证(aiAuth)的 hello 才放行。测试固定 LARES_AI_MEMBER_KEY 以便自己算凭证
const MEMBER_KEY = 'aim-member-key-' + randomBytes(8).toString('hex');
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m, 'utf8').digest('hex');
const aiIdFor = (cid) => `u_ai_${crypto.createHash('sha256').update(cid).digest('hex').slice(0, 8)}`;
const aiSecretFor = (cid) => hmac(MEMBER_KEY, `lares-ai-member:${cid}`);
/// hello 附加字段:aiAuth = {circleId, proof: HMAC(圈密钥, nonce:userId:circleId)}
const aiExtra = (cid, secret = aiSecretFor(cid)) => (nonce, userId) => ({ aiAuth: { circleId: cid, proof: hmac(secret, `${nonce}:${userId}:${cid}`) } });
let AI = aiIdFor('aim_env');
const T = makeChecker();
const { check } = T;

function fakeBlob(text) {
  const key = randomBytes(32);
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, nonce);
  const ct = Buffer.concat([c.update(JSON.stringify({ text }), 'utf8'), c.final()]);
  return Buffer.concat([Buffer.from([1]), nonce, ct, c.getAuthTag()]).toString('base64');
}

// 极简假 APNs(只记录请求;证书用 test/fixtures 里的测试专用自签证书)
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
      requests.push({ at: Date.now(), token: p.startsWith('/3/device/') ? p.slice('/3/device/'.length) : '', body });
      stream.respond({ ':status': 200, 'apns-id': crypto.randomUUID() });
      stream.end();
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({
      port: server.address().port,
      requests,
      close: () => new Promise((r) => server.close(r)),
    }));
  });
}

async function main() {
  console.log('AI 成员不算人(u_ai_*)\n');
  const fake = await startFakeApns();
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-aim-'));
  const srv = boot(PORT, dataDir, GLOBAL_PASS, {
    LARES_APNS_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    LARES_APNS_KEY_ID: 'TESTKEY123',
    LARES_APNS_TEAM_ID: '7CH28564U7',
    LARES_APNS_HOST_OVERRIDE: `https://127.0.0.1:${fake.port}`,
    LARES_APNS_INSECURE_TLS: '1',
    LARES_PUSH_ACTIVE_THROTTLE_MS: '1',
    // 「空圈来人」= 活动推送触发器 arrive(默认关),本测试沿用旧语义把它打开
    LARES_PUSH_ARRIVE_DEFAULT: '1',
    LARES_PUSH_RECENT_MS: '1',
    LARES_AI_MEMBER_KEY: MEMBER_KEY,
  });
  const clients = [];
  const C = async (opts) => { const c = await connect(PORT, opts); clients.push(c); return c; };
  try {
    check(await waitHealth(PORT), '服务端启动');

    // ── 1. 大厅人数 + 推送 + 敲门(env 圈,v1 全站口令)──
    console.log('\n[大厅 count / 推送 / 敲门]');
    {
      const cid = 'aim_env';
      const sub = await C({ userId: 'u_sub', name: 'Sub', auth: v1Auth(GLOBAL_PASS, cid) });
      check(sub.kind === 'welcome', '订阅者连上', sub.msg);

      // u_ai_ 保留:冒充者(无凭证 / 错凭证 / 别圈凭证 / id 与圈不符)一律 userId_reserved
      const spoof1 = await C({ userId: AI, name: '假AI', auth: v1Auth(GLOBAL_PASS, cid) });
      check(spoof1.kind === 'error' && spoof1.msg?.message === 'userId_reserved', '冒充 u_ai_(无凭证)-> userId_reserved', spoof1.msg);
      const spoof2 = await C({ userId: AI, name: '假AI', auth: v1Auth(GLOBAL_PASS, cid), helloExtra: aiExtra(cid, 'f'.repeat(64)) });
      check(spoof2.kind === 'error' && spoof2.msg?.message === 'userId_reserved', '冒充 u_ai_(错凭证)-> userId_reserved', spoof2.msg);
      const spoof3 = await C({ userId: 'u_ai_test1234', name: '假AI', auth: v1Auth(GLOBAL_PASS, cid), helloExtra: aiExtra(cid) });
      check(spoof3.kind === 'error' && spoof3.msg?.message === 'userId_reserved', '真凭证 + 非本圈派生 id -> userId_reserved', spoof3.msg);
      const spoof4 = await C({ userId: aiIdFor('other_c'), name: '假AI', auth: v1Auth(GLOBAL_PASS, cid), helloExtra: aiExtra('other_c') });
      check(spoof4.kind === 'error' && spoof4.msg?.message === 'userId_reserved', '别圈凭证用于本圈握手 -> userId_reserved', spoof4.msg);
      const TOKEN = randomBytes(32).toString('hex');
      const reg = await sub.req({ t: 'push_register', provider: 'apns', token: TOKEN, env: 'sandbox', lang: 'en', circles: [{ circleId: cid, name: 'Home', muted: false }] }, (m) => m.t === 'push_registered' || m.t === 'push_error');
      check(reg?.t === 'push_registered', '订阅推送', reg);

      const ai = await C({ userId: AI, name: '炉灵', auth: v1Auth(GLOBAL_PASS, cid), helloExtra: aiExtra(cid) });
      check(ai.kind === 'welcome', 'supervisor 凭证的 AI 成员 hello 成功', ai.msg);
      sub.drain(() => true);
      let t0 = Date.now();
      const aiRoom = await join(ai, cid);
      check(aiRoom?.members?.some((m) => m.userId === AI), 'AI 自己的 room 快照里有它', aiRoom);
      const sum1 = await sub.waitFor((m) => m.t === 'circle_summary' && m.circleId === cid);
      check(sum1?.count === 0 && sum1.names.length === 0 && sum1.ai === 1, '只有 AI 在房:count=0、names=[]、ai=1', sum1);
      await wait(500);
      check(!fake.requests.some((r) => r.token === TOKEN && r.at >= t0), 'AI 进空圈不触发「房间亮了」推送', fake.requests.length);

      // 敲门模式:只剩 AI 也算空房,真人直接进
      const setter = await C({ userId: 'u_setter', auth: v1Auth(GLOBAL_PASS, cid) });
      await join(setter, cid);
      setter.send({ t: 'knock_mode_set', circleId: cid, enabled: true });
      await wait(150);
      setter.send({ t: 'leave', circleId: cid });
      await wait(150);

      sub.drain(() => true);
      t0 = Date.now();
      const alice = await C({ userId: 'u_alice', name: 'Alice', auth: v1Auth(GLOBAL_PASS, cid) });
      alice.send({ t: 'join', circleId: cid });
      const first = await alice.waitFor((m) => (m.t === 'room' && m.circleId === cid) || m.t === 'knock_waiting');
      check(first?.t === 'room', '敲门圈只剩 AI -> 真人直接进房(不用等放行)', first);
      check(first?.members?.length === 2 && first.members.some((m) => m.userId === AI), '房间视图仍包含 AI 座位', first?.members);
      const push = await (async () => {
        const end = Date.now() + 2000;
        while (Date.now() < end) {
          const hit = fake.requests.find((r) => r.token === TOKEN && r.at >= t0);
          if (hit) return hit;
          await wait(20);
        }
        return null;
      })();
      check(Boolean(push) && /Alice/.test(push.body?.aps?.alert?.body ?? ''), 'AI 在场时第一个真人进房 -> 推送「Alice is in the circle」', push?.body);
      const sum2 = await sub.waitFor((m) => m.t === 'circle_summary' && m.circleId === cid && m.count === 1);
      check(sum2?.count === 1 && JSON.stringify(sum2.names) === '["Alice"]' && sum2.ai === 1, '真人 + AI:count=1、names=[Alice]、ai=1', sum2);

      // 新连上来的大厅连接拿到的初始摘要同样排除 AI
      const late = await C({ userId: 'u_late', auth: v1Auth(GLOBAL_PASS, cid) });
      const sum3 = await late.waitFor((m) => m.t === 'circle_summary' && m.circleId === cid);
      check(sum3?.count === 1 && sum3.ai === 1, 'hello 时下发的摘要也排除 AI', sum3);
      alice.send({ t: 'leave', circleId: cid });
      ai.send({ t: 'leave', circleId: cid });
      await wait(150);
    }

    // ── 2. 专注学习 + E2EE 转写中继(注册圈)──
    console.log('\n[专注学习]');
    const { cid, verifier, ownerKey, owner } = await registerCircle(PORT, PASSCODE, 'u_owner');
    clients.push(owner);
    AI = aiIdFor(cid);
    const A = await C({ userId: 'u_a', name: 'Alice', auth: v2Auth(verifier, cid) });
    const ai = await C({ userId: AI, name: '炉灵', auth: v2Auth(verifier, cid), helloExtra: aiExtra(cid) });
    await join(A, cid);
    await join(ai, cid);
    const inst = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.focus' }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    check(inst?.t === 'plugin_installed', '圈主装 lares.focus', inst);
    const st0 = await A.waitFor((m) => m.t === 'focus_status' && m.enabled === true);
    check(st0?.members?.length === 1 && st0.members[0].userId === 'u_a', 'focus_status 成员不含 AI', st0?.members);
    owner.send({ t: 'focus_start', circleId: cid, ownerKey });
    check(Boolean(await A.waitFor((m) => m.t === 'focus_notice' && m.kind === 'started')), '开番茄钟');
    await wait(1200);
    const fr = await ai.req({ t: 'focus_away', circleId: cid }, (m) => m.t === 'focus_error' || (m.t === 'focus_notice' && m.kind === 'away'), 800);
    check(fr?.t === 'focus_error' && fr.reason === 'not_in_room', 'AI 报离开 -> not_in_room(不在计时表里)', fr);
    owner.drain(() => true);
    owner.send({ t: 'focus_get', circleId: cid });
    const st = await owner.waitFor((m) => m.t === 'focus_status');
    const bd = await owner.waitFor((m) => m.t === 'focus_board');
    check(st?.members?.length === 1 && !st.members.some((m) => m.userId === AI), 'focus_get status 不含 AI', st?.members);
    const boards = [bd?.today, bd?.week, bd?.all];
    check(boards.every((b) => Array.isArray(b) && b.some((x) => x.userId === 'u_a') && !b.some((x) => x.userId === AI)), '排行榜 today/week/all 有 Alice、无 AI', bd);
    // AI 出房:不触发 left_early
    A.drain(() => true);
    ai.send({ t: 'leave', circleId: cid });
    const le = await A.waitFor((m) => m.t === 'focus_notice' && m.kind === 'left_early', 600);
    check(le === null, 'AI 专注期出房不发 left_early', le);
    owner.send({ t: 'focus_stop', circleId: cid, ownerKey });
    await wait(150);

    console.log('\n[E2EE 转写中继]');
    let r = await owner.req({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_ok', '开转写', r);
    r = await owner.req({ t: 'circle_e2ee_set', circleId: cid, enabled: true, ownerKey }, ownerReply('circle_e2ee_set'));
    check(r?.t === 'owner_ok', '开 E2EE', r);
    // E2EE 圈里 AI 照理不会被拉起;即便它进了房,也不能收密文
    const ai2 = await C({ userId: AI, name: '炉灵', deviceId: 'ai-2', auth: v2Auth(verifier, cid), helloExtra: aiExtra(cid) });
    await join(ai2, cid);
    const B = await C({ userId: 'u_b', name: 'Bob', auth: v2Auth(verifier, cid) });
    await join(B, cid);
    await wait(150);
    for (const c of [ai2, B]) c.drain((m) => m.t === 'transcript_relay');
    const relayReply = (m) => m.t === 'transcript_relayed' || (m.t === 'transcript_error' && m.op === 'relay');
    r = await A.req({ t: 'transcript_relay', circleId: cid, blob: fakeBlob('hello') }, relayReply);
    check(r?.t === 'transcript_relayed', '真人中继密文', r);
    const gotB = await B.waitFor((m) => m.t === 'transcript_relay', 1500);
    check(Boolean(gotB), '真人 Bob 实时收到', gotB);
    const gotAi = await ai2.waitFor((m) => m.t === 'transcript_relay', 500);
    check(gotAi === null, 'AI 在线不收密文', gotAi);
    await wait(150);
    const relayFile = path.join(dataDir, 'transcript_relay', encodeURIComponent(cid) + '.json');
    const q = existsSync(relayFile) ? JSON.parse(readFileSync(relayFile, 'utf8')) : null;
    check(q && !q.members.includes(AI) && !q.queues[AI] && q.members.includes('u_b'), '离线队列名单 / 队列里没有 AI', q && { members: q.members, queues: Object.keys(q.queues) });
    // AI 重连 hello / 进房也不补推
    await ai2.close();
    const ai3 = await C({ userId: AI, name: '炉灵', deviceId: 'ai-3', auth: v2Auth(verifier, cid), helloExtra: aiExtra(cid) });
    await join(ai3, cid);
    const pend = await ai3.waitFor((m) => m.t === 'transcript_relay', 500);
    check(pend === null, 'AI 重连不补推积压密文', pend);
  } finally {
    for (const c of clients) await c.close?.().catch?.(() => {});
    await stop(srv);
    await fake.close();
    if (T.fail && !process.env.DEBUG) console.log(srv.out.slice(-3000));
  }
}

await main();
console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
process.exit(T.fail === 0 ? 0 : 1);
