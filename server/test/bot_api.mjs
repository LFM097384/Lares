// 机器人 token + REST API(/api/v1/*)端到端验证。契约:docs/plans/transcript-bot-contract.md §5,docs/bot-api.md。
//
// 真实服务端进程 + 本地假 LiveKit Twirp 端点(记录 SendData 请求)。不 import 服务端代码。
// speak 只测 WAV 校验(400/413)与 rtc-node 不可用时的 501;真实发声见 tool/bot_api_e2e.mjs。
//
// 用法:node test/bot_api.mjs     (DEBUG=1 显示服务端 stderr)

import http from 'node:http';
import { createHmac, randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  wait, makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v2Auth, ownerReply, sha256,
} from './lib/harness.mjs';

const PORT = 18982;
const GLOBAL_PASS = 'bot-global-' + randomBytes(4).toString('hex');
const PASSCODE = 'bot-pass-' + randomBytes(4).toString('hex');
const LK_KEY = 'APItestkey';
const LK_SECRET = 'test-secret-' + randomBytes(12).toString('hex');
const T = makeChecker();
const { check } = T;
const BASE = `http://127.0.0.1:${PORT}`;

// ── 假 LiveKit(Twirp JSON)──
function startFakeLiveKit() {
  const requests = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let body = null;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* 非 JSON */ }
      requests.push({ method: req.method, url: req.url, auth: req.headers.authorization, ctype: req.headers['content-type'], body });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{}');
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port,
    requests,
    sendData: () => requests.filter((r) => r.url === '/twirp/livekit.RoomService/SendData'),
    close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }),
  })));
}

/// 手工验 HS256 JWT,返回 payload 或 null
function verifyJwt(jwt, secret) {
  const [h, p, s] = String(jwt).split('.');
  if (!s) return null;
  const expect = createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url');
  if (expect !== s) return null;
  const header = JSON.parse(Buffer.from(h, 'base64url').toString());
  if (header.alg !== 'HS256') return null;
  return JSON.parse(Buffer.from(p, 'base64url').toString());
}

function decodeChatFrame(b64) {
  const b = Buffer.from(b64, 'base64');
  const n = b.readUInt32BE(0);
  return { header: JSON.parse(b.subarray(4, 4 + n).toString('utf8')), rest: b.length - 4 - n };
}

function makeWav({ rate = 16000, seconds = 0.5, channels = 1, bits = 16, format = 1, extraChunk = false } = {}) {
  const n = Math.floor(rate * seconds);
  const blockAlign = channels * (bits / 8);
  const data = Buffer.alloc(n * blockAlign);
  if (bits === 16) for (let i = 0; i < n; i++) data.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 440 * i / rate) * 8000), i * blockAlign);
  const fmt = Buffer.alloc(24);
  fmt.write('fmt ', 0, 'ascii'); fmt.writeUInt32LE(16, 4);
  fmt.writeUInt16LE(format, 8); fmt.writeUInt16LE(channels, 10); fmt.writeUInt32LE(rate, 12);
  fmt.writeUInt32LE(rate * blockAlign, 16); fmt.writeUInt16LE(blockAlign, 20); fmt.writeUInt16LE(bits, 22);
  const list = extraChunk ? Buffer.concat([Buffer.from('LIST'), Buffer.from([3, 0, 0, 0]), Buffer.from('abc\0')]) : Buffer.alloc(0);
  const dh = Buffer.alloc(8); dh.write('data', 0, 'ascii'); dh.writeUInt32LE(data.length, 4);
  const body = Buffer.concat([Buffer.from('WAVE'), fmt, list, dh, data]);
  const riff = Buffer.alloc(8); riff.write('RIFF', 0, 'ascii'); riff.writeUInt32LE(body.length, 4);
  return Buffer.concat([riff, body]);
}

const api = (token, p, opts = {}) => fetch(BASE + p, {
  ...opts,
  headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(opts.json ? { 'content-type': 'application/json' } : {}), ...(opts.headers ?? {}) },
  body: opts.json ? JSON.stringify(opts.json) : opts.body,
});
const jsonOf = async (res) => { try { return await res.json(); } catch { return null; } };

/// 打开 SSE,逐事件收集
async function openSse(token, p = '/api/v1/events') {
  const ctrl = new AbortController();
  const res = await fetch(BASE + p, { headers: { authorization: `Bearer ${token}` }, signal: ctrl.signal });
  const sse = { res, raw: '', events: [], keepalives: 0, ended: false, ctrl, waiters: [] };
  if (!res.ok) return sse;
  (async () => {
    const dec = new TextDecoder();
    let buf = '';
    try {
      for await (const chunk of res.body) {
        const s = dec.decode(chunk, { stream: true });
        sse.raw += s;
        buf += s;
        let i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const block = buf.slice(0, i);
          buf = buf.slice(i + 2);
          if (block.startsWith(': keepalive')) { sse.keepalives++; continue; }
          const ev = {};
          for (const line of block.split('\n')) {
            const m = /^(id|event|data): (.*)$/.exec(line);
            if (m) ev[m[1]] = m[2];
          }
          if (!ev.event) continue;
          ev.data = JSON.parse(ev.data);
          sse.events.push(ev);
          for (const w of [...sse.waiters]) if (w.pred(ev)) { sse.waiters.splice(sse.waiters.indexOf(w), 1); clearTimeout(w.t); w.res(ev); }
        }
      }
    } catch { /* abort */ }
    sse.ended = true;
  })();
  sse.waitFor = (pred, ms = 3000) => {
    const hit = sse.events.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((res) => { const w = { pred, res, t: setTimeout(() => { sse.waiters.splice(sse.waiters.indexOf(w), 1); res(null); }, ms) }; sse.waiters.push(w); });
  };
  sse.close = () => ctrl.abort();
  return sse;
}

async function main() {
  const lk = await startFakeLiveKit();
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-bot-'));
  const child = boot(PORT, dataDir, GLOBAL_PASS, {
    LIVEKIT_URL: `ws://127.0.0.1:${lk.port}`,
    LIVEKIT_API_KEY: LK_KEY,
    LIVEKIT_API_SECRET: LK_SECRET,
    LARES_SSE_KEEPALIVE_MS: '300',
    LARES_DISABLE_RTC_NODE: '1',
  });
  const open = [];
  const sses = [];
  const C = async (opts) => { const c = await connect(PORT, opts); open.push(c); return c; };
  try {
    if (!(await waitHealth(PORT))) throw new Error('服务端启动超时');
    const { cid, verifier, ownerKey, owner } = await registerCircle(PORT, PASSCODE);
    open.push(owner);
    const auth = () => v2Auth(verifier, cid);

    console.log('\n[token 管理:圈主闸门]');
    const alice = await C({ userId: 'u_alice', name: 'Alice', auth: auth() });
    for (const op of ['bot_token_create', 'bot_token_list', 'bot_token_revoke']) {
      const r = await alice.req({ t: op, circleId: cid, name: 'X', id: 'b_x', ownerKey: 'a'.repeat(64) }, ownerReply(op));
      check(r?.t === 'owner_error' && r.reason === 'not_owner', `${op} 非圈主 -> not_owner`, r);
    }
    let r = await owner.req({ t: 'bot_token_create', circleId: cid, name: '', ownerKey }, ownerReply('bot_token_create'));
    check(r?.reason === 'bad_name', '空名字 -> bad_name', r);
    r = await owner.req({ t: 'bot_token_create', circleId: cid, name: 'x'.repeat(33), ownerKey }, ownerReply('bot_token_create'));
    check(r?.reason === 'bad_name', '名字 33 字 -> bad_name', r);
    owner.send({ t: 'bot_token_create', circleId: cid, name: '小助手', ownerKey });
    const tok = await owner.waitFor((m) => m.t === 'bot_token');
    check(/^lrb_[A-Za-z0-9_-]{43}$/.test(tok?.token ?? '') && tok.name === '小助手' && tok.circleId === cid && /^b_/.test(tok.id) && tok.createdAt > 0,
      'bot_token {circleId,id,name,token,createdAt},token = lrb_+43 位 base64url', tok);
    owner.send({ t: 'bot_token_create', circleId: cid, name: 'Second', ownerKey });
    const tok2 = await owner.waitFor((m) => m.t === 'bot_token');
    owner.send({ t: 'bot_token_list', circleId: cid, ownerKey });
    const list = await owner.waitFor((m) => m.t === 'bot_tokens');
    check(list?.items?.length === 2 && list.items.every((x) => x.id && x.name && x.createdAt && !('token' in x) && !('sha256' in x)), 'bot_tokens 列表不含明文/哈希', list);
    const disk = readFileSync(path.join(dataDir, 'bot_tokens.json'), 'utf8');
    check(!disk.includes(tok.token) && disk.includes(sha256(tok.token)), '磁盘只存 sha256', null);

    console.log('\n[鉴权 401/403]');
    let res = await api(null, '/api/v1/circle');
    check(res.status === 401, '无 token -> 401', res.status);
    res = await api('lrb_' + 'A'.repeat(43), '/api/v1/circle');
    check(res.status === 401, '错 token -> 401', res.status);
    res = await api(tok.token.slice(0, -1), '/api/v1/circle');
    check(res.status === 401, '截断 token -> 401', res.status);
    res = await api(tok.token, '/api/v1/circle?circleId=c_someotherid');
    check(res.status === 403 && (await jsonOf(res))?.error === 'wrong_circle', 'circleId 不符 -> 403', res.status);
    res = await api(tok.token, `/api/v1/circle?circleId=${cid}`);
    check(res.status === 200, 'circleId 相符 -> 200', res.status);
    res = await api(tok.token, '/api/v1/nope');
    check(res.status === 404, '未知路径 -> 404', res.status);

    console.log('\n[GET /circle]');
    await join(alice, cid);
    alice.send({ t: 'status', status: 'busy' });
    await wait(100);
    res = await api(tok.token, '/api/v1/circle');
    let body = await jsonOf(res);
    check(body?.id === cid && body.e2ee === false && body.transcript === false && body.name === null, 'circle {id,name:null,e2ee,transcript}', body);
    const am = body?.members?.find((m) => m.userId === 'u_alice');
    check(am?.name === 'Alice' && am.status === 'busy' && am.muted === null && am.speaking === null, 'members 含 status,muted/speaking 如实 null', body?.members);

    console.log('\n[SSE]');
    const sse = await openSse(tok.token);
    sses.push(sse);
    check(sse.res.status === 200 && /text\/event-stream/.test(sse.res.headers.get('content-type')), 'events -> 200 text/event-stream', sse.res.status);
    const ready = await sse.waitFor((e) => e.event === 'ready');
    check(ready?.data?.circleId === cid && ready.data.bot?.id === tok.id && Array.isArray(ready.data.members) && /^\d+$/.test(ready.id), 'ready 事件(带 id: 行)', ready);
    await wait(700);
    check(sse.keepalives >= 1, `': keepalive' 注释行(${sse.keepalives} 次 / 700ms,间隔 300ms)`, sse.raw.slice(-200));
    check(/^id: \d+\nevent: ready\ndata: \{/m.test(sse.raw), '帧格式 id:/event:/data:', sse.raw.slice(0, 200));

    // 每 token 的 SSE 并发上限(默认 4):第 5 条 -> 429,关一条后又能开
    const extra = [];
    for (let i = 0; i < 3; i++) { const s = await openSse(tok.token); extra.push(s); sses.push(s); }
    check(extra.every((s) => s.res.status === 200), '同一 token 共 4 条 SSE 都 200', extra.map((s) => s.res.status));
    const over = await openSse(tok.token);
    check(over.res.status === 429 && (await jsonOf(over.res))?.error === 'too_many_streams', '第 5 条 SSE -> 429 too_many_streams', over.res.status);
    for (const s of extra) s.close();
    await wait(200);
    const again = await openSse(tok2.token);
    sses.push(again);
    check(again.res.status === 200, '上限按 token 计:另一个 token 不受影响', again.res.status);
    again.close();

    // `bot:` 前缀的 userId 是服务器保留的机器人身份,成员不能自报
    const fakeBot = await connect(PORT, { userId: `bot:${tok.id}`, name: '小助手', auth: auth() });
    open.push(fakeBot);
    check(fakeBot.kind === 'error' && fakeBot.msg?.message === 'userId_reserved', 'hello userId=bot:* -> userId_reserved', fakeBot.kind);

    const bob = await C({ userId: 'u_bob', name: 'Bob', auth: auth() });
    await join(bob, cid);
    let ev = await sse.waitFor((e) => e.event === 'join' && e.data.userId === 'u_bob');
    check(ev?.data?.name === 'Bob', 'join 事件', ev);
    bob.send({ t: 'status', status: 'away' });
    ev = await sse.waitFor((e) => e.event === 'presence' && e.data.userId === 'u_bob');
    check(ev?.data?.status === 'away', 'presence 事件', ev);
    // 转写开启后,成员追加 -> SSE transcript
    await owner.req({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey }, ownerReply('circle_transcript_set'));
    r = await bob.req({ t: 'transcript_append', circleId: cid, id: 'l1', text: '大家好' }, (m) => m.t === 'transcript_appended' || m.t === 'transcript_error');
    check(r?.t === 'transcript_appended', '成员追加一条', r);
    ev = await sse.waitFor((e) => e.event === 'transcript' && e.data.id === 'l1');
    check(ev?.data?.userId === 'u_bob' && ev.data.text === '大家好' && ev.data.seq === r?.seq, 'SSE transcript 事件 = item', ev);
    bob.send({ t: 'leave' });
    ev = await sse.waitFor((e) => e.event === 'leave' && e.data.userId === 'u_bob');
    check(Boolean(ev), 'leave 事件', ev);

    console.log('\n[GET /transcript]');
    res = await api(tok.token, '/api/v1/transcript?limit=10');
    body = await jsonOf(res);
    check(res.status === 200 && body.items?.[0]?.text === '大家好' && body.more === false, '归档分页', body);
    res = await api(tok.token, '/api/v1/transcript?limit=500');
    check(res.status === 400, 'limit 500 -> 400', res.status);

    console.log('\n[POST /messages -> SendData]');
    const before = lk.sendData().length;
    res = await api(tok.token, '/api/v1/messages', { method: 'POST', json: { text: '机器人来了 👋' } });
    body = await jsonOf(res);
    check(res.status === 200 && body?.ok && body.id, 'messages -> 200 {ok,id}', body);
    const sd = lk.sendData()[before];
    check(sd?.method === 'POST' && sd.url === '/twirp/livekit.RoomService/SendData' && /application\/json/.test(sd.ctype), 'POST /twirp/livekit.RoomService/SendData JSON', sd && { url: sd.url, ctype: sd.ctype });
    check(sd?.body?.room === cid && sd.body.topic === 'lares.chat' && (sd.body.kind === 'RELIABLE' || sd.body.kind === 0) && Array.isArray(sd.body.destination_identities) && sd.body.destination_identities.length === 0,
      'body {room,kind:RELIABLE,topic:lares.chat,destination_identities:[]}', sd?.body);
    const frame = sd ? decodeChatFrame(sd.body.data) : null;
    const h = frame?.header;
    check(h?.v === 1 && h.t === 'text' && h.id === body?.id && h.sid === `bot:${tok.id}` && h.sn === '小助手' && h.cid === cid && typeof h.ts === 'number' && h.body === '机器人来了 👋' && h.bot === true && frame.rest === 0,
      '帧 = 4 字节长度 + header{v,t,id,sid:bot:<id>,sn,cid,ts,body,bot:true}', frame);
    const claims = verifyJwt(sd?.auth?.replace(/^Bearer /, ''), LK_SECRET);
    check(claims?.iss === LK_KEY && claims.video?.room === cid && claims.video?.roomAdmin === true && claims.exp > Date.now() / 1000, 'JWT 用 secret 验签通过,iss=key,video{room,roomAdmin:true}', claims);
    check(verifyJwt(sd?.auth?.replace(/^Bearer /, ''), 'wrong') === null, 'JWT 换个 secret 验不过', null);
    ev = await sse.waitFor((e) => e.event === 'chat' && e.data.id === body?.id);
    check(ev?.data?.body === '机器人来了 👋' && ev.data.bot === true, 'SSE chat 事件', ev);
    res = await api(tok.token, '/api/v1/messages', { method: 'POST', json: { text: '' } });
    check(res.status === 400, '空文本 -> 400', res.status);
    res = await api(tok.token, '/api/v1/messages', { method: 'POST', json: { text: 'x'.repeat(2001) } });
    check(res.status === 400, '2001 字 -> 400', res.status);
    res = await api(tok.token, '/api/v1/messages', { method: 'POST', body: '{bad', headers: { 'content-type': 'application/json' } });
    check(res.status === 400 && (await jsonOf(res))?.error === 'bad_json', '坏 JSON -> 400 bad_json', res.status);
    res = await api(tok.token, '/api/v1/messages', { method: 'POST', body: JSON.stringify({ text: 'a', pad: 'x'.repeat(17000) }), headers: { 'content-type': 'application/json' } });
    check(res.status === 413, '16 KB 以上 JSON -> 413', res.status);

    console.log('\n[POST /captions]');
    alice.drain(() => true);
    let n0 = lk.sendData().length;
    res = await api(tok.token, '/api/v1/captions', { method: 'POST', json: { text: '今天天' } });
    const c1 = await jsonOf(res);
    res = await api(tok.token, '/api/v1/captions', { method: 'POST', json: { text: '今天天气不错', final: true } });
    const c2 = await jsonOf(res);
    check(c1?.id && c1.id === c2?.id && c2.seq === c1.seq + 1 && c2.final === true, 'partial 与 final 同 id,seq 递增', [c1, c2]);
    const caps = lk.sendData().slice(n0).map((x) => ({ topic: x.body.topic, f: JSON.parse(Buffer.from(x.body.data, 'base64').toString('utf8')) }));
    check(caps.length === 2 && caps.every((x) => x.topic === 'lares.cap'), '两帧都走 topic lares.cap', caps.map((x) => x.topic));
    check(caps[1]?.f?.t === 'cap' && caps[1].f.id === c2.id && caps[1].f.seq === c2.seq && caps[1].f.text === '今天天气不错' && caps[1].f.final === true
      && caps[1].f.bot?.id === tok.id && caps[1].f.bot?.name === '小助手', 'cap 帧 {t,id,seq,text,final,bot:{id,name}}', caps[1]?.f);
    check(caps[0]?.f?.final === false, 'partial 帧 final:false', caps[0]?.f);
    ev = await sse.waitFor((e) => e.event === 'transcript' && e.data.userId === `bot:${tok.id}`);
    check(ev?.data?.text === '今天天气不错' && ev.data.name === '小助手' && ev.data.seq === c2.archivedSeq, '定稿字幕归档 + SSE transcript(userId bot:<id>)', ev);
    const tl = await alice.waitFor((m) => m.t === 'transcript_line' && m.item.userId === `bot:${tok.id}`);
    check(Boolean(tl), '在房成员收到 transcript_line', tl);
    check(c1?.archivedSeq === null, 'partial 不归档', c1);
    res = await api(tok.token, '/api/v1/captions', { method: 'POST', json: { text: '下一句', final: true } });
    const c3 = await jsonOf(res);
    check(c3?.id && c3.id !== c2.id, '定稿之后换新 id', c3);

    console.log('\n[POST /speak 校验]');
    const big = Buffer.alloc(6 * 1024 * 1024 + 10);
    res = await api(tok2.token, '/api/v1/speak', { method: 'POST', body: big, headers: { 'content-type': 'audio/wav' } });
    check(res.status === 413, '> 6 MB -> 413', res.status);
    res = await api(tok2.token, '/api/v1/speak', { method: 'POST', body: Buffer.from('hello world, not a wav'), headers: { 'content-type': 'audio/wav' } });
    body = await jsonOf(res);
    check(res.status === 400 && body?.error === 'bad_wav', '非 WAV -> 400 bad_wav', body);
    res = await api(tok2.token, '/api/v1/speak', { method: 'POST', body: makeWav({ channels: 2 }) });
    body = await jsonOf(res);
    check(res.status === 400 && body?.detail === 'not_mono', '双声道 -> 400 not_mono', body);
    res = await api(tok2.token, '/api/v1/speak', { method: 'POST', body: makeWav({ bits: 8 }) });
    check(res.status === 400 && (await jsonOf(res))?.detail === 'not_16bit', '8 bit -> 400 not_16bit', res.status);
    res = await api(tok2.token, '/api/v1/speak', { method: 'POST', body: makeWav({ format: 3, bits: 16 }) });
    check(res.status === 400 && (await jsonOf(res))?.detail === 'not_pcm', 'float 格式 -> 400 not_pcm', res.status);
    res = await api(tok2.token, '/api/v1/speak', { method: 'POST', body: makeWav({ rate: 8000, seconds: 61 }) });
    check(res.status === 400 && (await jsonOf(res))?.detail === 'too_long', '61 秒 -> 400 too_long', res.status);
    res = await api(tok2.token, '/api/v1/speak', { method: 'POST', body: makeWav({ rate: 22050, extraChunk: true }) });
    body = await jsonOf(res);
    check(res.status === 501 && body?.error === 'speak_unavailable', '合法 WAV(带 LIST 块)但 rtc-node 不可用 -> 501 speak_unavailable', body);

    console.log('\n[429]');
    let got429 = null;
    for (let i = 0; i < 15 && !got429; i++) {
      res = await api(tok2.token, '/api/v1/messages', { method: 'POST', json: { text: 'spam ' + i } });
      if (res.status === 429) got429 = res;
    }
    check(got429 && Number(got429.headers.get('retry-after')) >= 1, '消息超 10 条/10 秒 -> 429 + retry-after', got429?.status);
    res = await api(tok.token, '/api/v1/circle');
    check(res.status === 200, '限速按 token 计,另一个 token 不受影响', res.status);
    let gen429 = null;
    for (let i = 0; i < 70 && !gen429; i++) {
      res = await api(tok2.token, '/api/v1/circle');
      if (res.status === 429) gen429 = res;
    }
    check(gen429 && gen429.headers.get('retry-after'), '总请求超 60/分钟 -> 429', gen429?.status);

    console.log('\n[E2EE 圈 -> 409]');
    await owner.req({ t: 'circle_e2ee_set', circleId: cid, enabled: true, ownerKey }, ownerReply('circle_e2ee_set'));
    n0 = lk.sendData().length;
    for (const [p, opts] of [
      ['/api/v1/messages', { method: 'POST', json: { text: 'x' } }],
      ['/api/v1/captions', { method: 'POST', json: { text: 'x', final: true } }],
      ['/api/v1/speak', { method: 'POST', body: makeWav() }],
      ['/api/v1/transcript', {}],
    ]) {
      res = await api(tok.token, p, opts);
      body = await jsonOf(res);
      check(res.status === 409 && body?.error === 'e2ee', `E2EE ${p} -> 409 e2ee`, [res.status, body]);
    }
    check(lk.sendData().length === n0, 'E2EE 圈一包都没发给 LiveKit', lk.sendData().length - n0);
    res = await api(tok.token, '/api/v1/circle');
    body = await jsonOf(res);
    check(res.status === 200 && body.e2ee === true, 'E2EE 圈 GET /circle 仍可用,e2ee:true', body);

    console.log('\n[吊销]');
    check(!sse.ended, '吊销前 SSE 仍连着', null);
    r = await owner.req({ t: 'bot_token_revoke', circleId: cid, id: tok.id, ownerKey }, ownerReply('bot_token_revoke'));
    check(r?.t === 'owner_ok', 'bot_token_revoke -> owner_ok', r);
    await wait(300);
    check(sse.ended, '吊销后 SSE 立即被关闭', null);
    res = await api(tok.token, '/api/v1/circle');
    check(res.status === 401, '吊销后 -> 401', res.status);
    r = await owner.req({ t: 'bot_token_revoke', circleId: cid, id: tok.id, ownerKey }, ownerReply('bot_token_revoke'));
    check(r?.t === 'owner_error' && r.reason === 'not_found', '重复吊销 -> not_found', r);
    owner.send({ t: 'bot_token_list', circleId: cid, ownerKey });
    const list2 = await owner.waitFor((m) => m.t === 'bot_tokens');
    check(list2?.items?.length === 1 && list2.items[0].id === tok2.id, '列表只剩一个', list2);
  } finally {
    for (const s of sses) s.close();
    for (const c of open) await c.close();
    await stop(child);
    await lk.close();
    if (process.env.DEBUG) console.log(child.out);
  }
  console.log(`\n${T.fail === 0 ? '全部通过' : `${T.fail} 项失败`}(${T.pass} 通过)`);
  process.exit(T.fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('✗ 测试异常:', e);
  process.exit(1);
});
