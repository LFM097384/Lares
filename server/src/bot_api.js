// 机器人 REST API:/api/v1/*(契约 §5,完整说明见 docs/bot-api.md)。
//
// 鉴权:Authorization: Bearer lrb_...(圈主经 WS bot_token_create 签发,一个 token 只属于一个圈)。
// 服务器能看见的只有信令层:presence、明文转写归档、机器人自己经服务器发的消息。
// 成员之间的聊天走 LiveKit data channel,服务器**看不见** —— 所以 SSE 的 chat 事件只含机器人发的。
//
// 本模块不碰 WS 内部状态:index.js 通过 hooks 把需要的读写能力递进来。

import crypto from 'node:crypto';
import { TokenBuckets } from './ratelimit.js';
import { encodeChatFrame, CHAT_TOPIC, CAPTION_TOPIC } from './livekit_senddata.js';
import { parseWav, WavError, WAV_MAX_BYTES, loadRtcNode, speakIntoRoom } from './bot_speak.js';
import { TEXT_MAX, ID_MAX, PAGE_MAX, PAGE_DEFAULT } from './transcripts.js';

export const JSON_BODY_MAX = 16 * 1024;

class HttpError extends Error {
  constructor(status, body, headers = {}) {
    super(body?.error ?? String(status));
    this.status = status;
    this.body = body;
    this.headers = headers;
  }
}

function readRaw(req, max) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > max) {
      reject(new HttpError(413, { error: 'too_large', max }));
      req.resume();
      return;
    }
    const chunks = [];
    let size = 0;
    let over = false;
    req.on('data', (c) => {
      if (over) return;
      size += c.length;
      if (size > max) {
        over = true;
        chunks.length = 0;
        reject(new HttpError(413, { error: 'too_large', max }));
        return; // 继续读完丢弃,让 413 能正常发回去
      }
      chunks.push(c);
    });
    req.on('end', () => { if (!over) resolve(Buffer.concat(chunks)); });
    req.on('error', reject);
  });
}

async function readJson(req) {
  const raw = await readRaw(req, JSON_BODY_MAX);
  if (raw.length === 0) return {};
  try {
    const v = JSON.parse(raw.toString('utf8'));
    if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error('not object');
    return v;
  } catch {
    throw new HttpError(400, { error: 'bad_json' });
  }
}

/**
 * @param {object} o
 * @param {ReturnType<import('./bot_tokens.js').createBotTokenStore>} o.tokens
 * @param {ReturnType<import('./transcripts.js').createTranscriptStore>} o.store
 * @param {{sendData:Function}|null} o.livekit   SendData;null = 没配 LiveKit
 * @param {{url:string, apiKey:string, apiSecret:string}|null} o.rtc  speak 用
 * @param {object} o.hooks
 *   circleInfo(circleId) -> {e2ee, transcript, ...}
 *   members(circleId) -> [{userId,name,status}]
 *   onBotTranscript(circleId, item)  机器人定稿字幕归档后,由 index.js 广播 transcript_line
 * @param {object} [o.env]
 */
export function createBotApi({ tokens, store, livekit, rtc, hooks, env = process.env, origin = '*' }) {
  const keepaliveMs = Number(env.LARES_SSE_KEEPALIVE_MS ?? 25_000);
  const sseMaxPerToken = Number(env.LARES_SSE_MAX_PER_TOKEN ?? 4);
  const sseMaxTotal = Number(env.LARES_SSE_MAX_TOTAL ?? 200);
  const general = new TokenBuckets({ capacity: 60, perSec: 1 }); // 60 次/分钟
  const posting = new TokenBuckets({ capacity: 10, perSec: 1 }); // 消息+字幕 10 条/10 秒
  const speakRate = new TokenBuckets({ capacity: 6, perSec: 0.1 }); // 6 次/分钟
  const speaking = new Set(); // tokenId:正在说话的(并发 1)
  /** @type {Map<string, Set<{res, tokenId, circleId}>>} circleId -> streams */
  const streams = new Map();
  let eventSeq = 0;
  const capState = new Map(); // tokenId -> {seq, openId}

  function writeEvent(res, event, data) {
    eventSeq += 1;
    res.write(`id: ${eventSeq}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  }

  /// index.js 调:把一条事件推给该圈所有 SSE 流
  function emit(circleId, event, data) {
    const set = streams.get(circleId);
    if (!set) return;
    for (const s of set) {
      try { writeEvent(s.res, event, data); } catch { /* 流已断,close 回调会清 */ }
    }
  }

  function closeStream(s) {
    const set = streams.get(s.circleId);
    set?.delete(s);
    if (set && set.size === 0) streams.delete(s.circleId);
    clearInterval(s.timer);
    try { s.res.end(); } catch { /* 已断 */ }
  }

  /// 吊销:立刻关掉该 token 的所有 SSE
  function closeToken(tokenId) {
    for (const set of [...streams.values()]) for (const s of [...set]) if (s.tokenId === tokenId) closeStream(s);
    capState.delete(tokenId);
    general.delete(tokenId); posting.delete(tokenId); speakRate.delete(tokenId);
  }

  function closeCircle(circleId) {
    for (const s of [...(streams.get(circleId) ?? [])]) closeStream(s);
  }

  function sweep() {
    general.sweep(); posting.sweep(); speakRate.sweep();
  }

  function authenticate(req, url) {
    const h = String(req.headers.authorization ?? '');
    const m = /^Bearer\s+(\S+)\s*$/i.exec(h);
    const rec = m ? tokens.verify(m[1]) : null;
    if (!rec) throw new HttpError(401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer' });
    const q = url.searchParams.get('circleId');
    if (q !== null && q !== rec.circleId) throw new HttpError(403, { error: 'wrong_circle' });
    return rec;
  }

  function limit(bucket, key) {
    const wait = bucket.take(key);
    if (wait > 0) {
      throw new HttpError(429, { error: 'rate_limited', retryAfterMs: wait }, { 'retry-after': String(Math.ceil(wait / 1000)) });
    }
  }

  function notE2ee(info) {
    if (info.e2ee === true) throw new HttpError(409, { error: 'e2ee' });
  }

  function needLiveKit() {
    if (!livekit) throw new HttpError(503, { error: 'rtc_not_configured' });
  }

  async function pushData(room, data, topic) {
    try {
      await livekit.sendData(room, data, topic);
    } catch (e) {
      console.error('[bot] SendData 失败:', e?.message ?? e);
      throw new HttpError(502, { error: 'livekit_failed' });
    }
  }

  function textOf(body) {
    const text = typeof body.text === 'string' ? body.text : '';
    if (text.trim().length === 0 || text.length > TEXT_MAX) throw new HttpError(400, { error: 'bad_text', max: TEXT_MAX });
    return text;
  }

  // ── 路由 ─────────────────────────────────────────────────────────────
  async function route(req, res, url, bot) {
    const p = url.pathname.replace(/\/+$/, '');
    const info = hooks.circleInfo(bot.circleId);
    const circleId = bot.circleId;

    if (p === '/api/v1/circle' && req.method === 'GET') {
      return [200, {
        id: circleId,
        name: null, // 圈名只存在于客户端,服务器不知道
        e2ee: info.e2ee === true,
        transcript: info.transcript === true,
        members: hooks.members(circleId).map((m) => ({
          userId: m.userId,
          name: m.name,
          status: m.status ?? null,
          // 静音 / 正在说话是媒体层状态,信令服务器看不到 —— 如实给 null
          muted: null,
          speaking: null,
        })),
        bot: { id: bot.id, name: bot.name },
      }];
    }

    if (p === '/api/v1/transcript' && req.method === 'GET') {
      notE2ee(info);
      const before = url.searchParams.has('before') ? Number(url.searchParams.get('before')) : undefined;
      const lim = url.searchParams.has('limit') ? Number(url.searchParams.get('limit')) : PAGE_DEFAULT;
      if ((before !== undefined && !Number.isInteger(before)) || !Number.isInteger(lim) || lim < 1 || lim > PAGE_MAX) {
        throw new HttpError(400, { error: 'bad_query' });
      }
      const page = await store.page(circleId, { before, limit: lim });
      return [200, { circleId, transcript: info.transcript === true, ...page }];
    }

    if (p === '/api/v1/events' && req.method === 'GET') {
      // 长连接要设上限:否则一个 token 就能开到 fd 耗尽
      let total = 0, mine = 0;
      for (const set of streams.values()) for (const s of set) { total += 1; if (s.tokenId === bot.id) mine += 1; }
      if (mine >= sseMaxPerToken || total >= sseMaxTotal) {
        throw new HttpError(429, { error: 'too_many_streams' }, { 'retry-after': '5' });
      }
      res.writeHead(200, {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-transform',
        connection: 'keep-alive',
        'x-accel-buffering': 'no', // 反代别攒包
        'access-control-allow-origin': origin,
      });
      res.write(': lares bot events\n\n');
      const s = { res, tokenId: bot.id, circleId, timer: null };
      s.timer = setInterval(() => { try { res.write(': keepalive\n\n'); } catch { /* close 会清 */ } }, keepaliveMs);
      if (!streams.has(circleId)) streams.set(circleId, new Set());
      streams.get(circleId).add(s);
      req.on('close', () => closeStream(s));
      res.on('error', () => closeStream(s));
      writeEvent(res, 'ready', {
        circleId,
        bot: { id: bot.id, name: bot.name },
        e2ee: info.e2ee === true,
        transcript: info.transcript === true,
        members: hooks.members(circleId).map((m) => ({ userId: m.userId, name: m.name, status: m.status ?? null })),
      });
      return null; // 长连接,不走统一响应
    }

    if (p === '/api/v1/messages' && req.method === 'POST') {
      const body = await readJson(req);
      notE2ee(info);
      const text = textOf(body);
      needLiveKit();
      limit(posting, bot.id);
      const header = {
        v: 1, t: 'text', id: crypto.randomUUID(),
        sid: `bot:${bot.id}`, sn: bot.name, cid: circleId, ts: Date.now(), body: text, bot: true,
      };
      await pushData(circleId, encodeChatFrame(header), CHAT_TOPIC);
      emit(circleId, 'chat', header);
      return [200, { ok: true, id: header.id, ts: header.ts }];
    }

    if (p === '/api/v1/captions' && req.method === 'POST') {
      const body = await readJson(req);
      notE2ee(info);
      const text = textOf(body);
      const fin = body.final === true;
      if (body.id !== undefined && (typeof body.id !== 'string' || !body.id || body.id.length > ID_MAX)) {
        throw new HttpError(400, { error: 'bad_id' });
      }
      needLiveKit();
      limit(posting, bot.id);
      // 同一句的 partial 共用 id(客户端按 id 整句替换);定稿后下一条换新 id
      const st = capState.get(bot.id) ?? { seq: 0, openId: null };
      const id = body.id ?? st.openId ?? `bc_${crypto.randomBytes(8).toString('hex')}`;
      st.seq += 1;
      st.openId = fin ? null : id;
      capState.set(bot.id, st);
      const frame = { t: 'cap', id, seq: st.seq, text, final: fin, bot: { id: bot.id, name: bot.name } };
      await pushData(circleId, Buffer.from(JSON.stringify(frame), 'utf8'), CAPTION_TOPIC);
      let archived = null;
      if (fin && info.transcript === true) {
        const { item, duplicate } = await store.append(circleId, {
          userId: `bot:${bot.id}`, name: bot.name, id, text, startedAt: Date.now(),
        });
        archived = item.seq;
        if (!duplicate) {
          hooks.onBotTranscript(circleId, item); // → transcript_line 广播 + SSE transcript
        }
      }
      return [200, { ok: true, id, seq: st.seq, final: fin, archivedSeq: archived }];
    }

    if (p === '/api/v1/speak' && req.method === 'POST') {
      notE2ee(info);
      if (speaking.has(bot.id)) {
        throw new HttpError(429, { error: 'speak_busy' }, { 'retry-after': '1' });
      }
      const raw = await readRaw(req, WAV_MAX_BYTES);
      let wav;
      try {
        wav = parseWav(raw);
      } catch (e) {
        if (e instanceof WavError) throw new HttpError(400, { error: 'bad_wav', detail: e.message });
        throw e;
      }
      if (!rtc) throw new HttpError(503, { error: 'rtc_not_configured' });
      const lib = await loadRtcNode();
      if (!lib) throw new HttpError(501, { error: 'speak_unavailable' });
      if (speaking.has(bot.id)) throw new HttpError(429, { error: 'speak_busy' }, { 'retry-after': '1' });
      limit(speakRate, bot.id);
      speaking.add(bot.id);
      const t0 = Date.now();
      try {
        await speakIntoRoom({ rtc: lib, url: rtc.url, apiKey: rtc.apiKey, apiSecret: rtc.apiSecret, room: circleId, bot, wav });
      } catch (e) {
        console.error('[bot] speak 失败:', e?.message ?? e);
        throw new HttpError(502, { error: 'speak_failed' });
      } finally {
        speaking.delete(bot.id);
      }
      return [200, { ok: true, sampleRate: wav.sampleRate, durationMs: Math.round(wav.durationSec * 1000), elapsedMs: Date.now() - t0 }];
    }

    throw new HttpError(404, { error: 'not_found' });
  }

  /// http 入口。返回 true = 已处理。
  async function handle(req, res, url) {
    if (!url.pathname.startsWith('/api/v1/') && url.pathname !== '/api/v1') return false;
    const reply = (status, body, headers = {}) => {
      if (res.headersSent) { try { res.end(); } catch { /* */ } return; }
      res.writeHead(status, {
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'access-control-allow-origin': origin,
        ...headers,
      });
      res.end(JSON.stringify(body));
    };
    try {
      const bot = authenticate(req, url);
      limit(general, bot.id);
      const out = await route(req, res, url, bot);
      if (out) reply(out[0], out[1]);
    } catch (e) {
      if (e instanceof HttpError) {
        reply(e.status, e.body, e.headers);
        // 请求体还没读完就回了错误(401/413 等):读完丢弃,别让客户端写到一半 EPIPE
        if (!req.complete) req.resume();
      } else {
        console.error('[bot] API 内部错误:', e);
        reply(500, { error: 'internal' });
      }
    }
    return true;
  }

  return { handle, emit, closeToken, closeCircle, sweep };
}
