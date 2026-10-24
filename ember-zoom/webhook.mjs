// ember-zoom · Zoom webhook(docs/plans/chatham/05-zoom-rtms-facts.md §1)。
//   x-zm-signature = "v0=" + hex(HMAC-SHA256(secretToken, "v0:" + x-zm-request-timestamp + ":" + rawBody)),时间戳单位秒。
//   endpoint.url_validation → {plainToken, encryptedToken: hex(HMAC-SHA256(secretToken, plainToken))}。
//   meeting.rtms_started / meeting.rtms_stopped / meeting.rtms_interrupted → onEvent(event, payload)。
// 所有请求(含 url_validation)先验签再处理:url_validation 回的是任意 plainToken 的 HMAC,
// 不验签就等于给任何人一个「用 webhook secret 签任意串」的预言机,可以伪造 "v0:ts:body" 的签名。
import { createHmac, timingSafeEqual } from 'node:crypto';

export const TOLERANCE_SEC = 300; // ±5 min
export const MAX_BODY_BYTES = 64 * 1024;
export const RTMS_EVENTS = Object.freeze(['meeting.rtms_started', 'meeting.rtms_stopped', 'meeting.rtms_interrupted']);

const hmacHex = (key, msg) => createHmac('sha256', String(key)).update(msg).digest('hex');

/// 签名(sim / 测试也用它):rawBody 是字符串或 Buffer,按原样参与 HMAC
export function signWebhook(secret, timestamp, rawBody) {
  const body = Buffer.isBuffer(rawBody) ? rawBody : Buffer.from(String(rawBody), 'utf8');
  return `v0=${createHmac('sha256', String(secret)).update(Buffer.concat([Buffer.from(`v0:${timestamp}:`, 'utf8'), body])).digest('hex')}`;
}

export const urlValidationResponse = (secret, plainToken) => ({ plainToken: String(plainToken), encryptedToken: hmacHex(secret, String(plainToken)) });

const header = (headers, name) => {
  const v = headers?.[name] ?? headers?.[name.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
};

/**
 * 验签。返回 {ok:true} 或 {ok:false, code}。code:no_secret / missing_headers / bad_timestamp / stale / bad_signature。
 * now 为毫秒(可注入)。比较用 timingSafeEqual,长度不同直接判失败(长度本身不是秘密:恒为 "v0=" + 64 hex)。
 */
export function verifyWebhook({ secret, headers, rawBody, now = Date.now(), toleranceSec = TOLERANCE_SEC }) {
  if (!secret) return { ok: false, code: 'no_secret' };
  const sig = header(headers, 'x-zm-signature');
  const ts = header(headers, 'x-zm-request-timestamp');
  if (typeof sig !== 'string' || typeof ts !== 'string' || !sig || !ts) return { ok: false, code: 'missing_headers' };
  if (!/^\d{1,12}$/.test(ts)) return { ok: false, code: 'bad_timestamp' };
  if (Math.abs(now / 1000 - Number(ts)) > toleranceSec) return { ok: false, code: 'stale' };
  const want = Buffer.from(signWebhook(secret, ts, rawBody), 'utf8');
  const got = Buffer.from(sig, 'utf8');
  if (got.length !== want.length || !timingSafeEqual(got, want)) return { ok: false, code: 'bad_signature' };
  return { ok: true };
}

function readBody(req, max) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    let over = false;
    req.on('data', (c) => {
      n += c.length;
      if (n > max) {
        // 超限:丢弃但读完(好让 413 能送达);远超上限才直接断
        over = true;
        chunks.length = 0;
        if (n > max * 16) req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => (over ? reject(Object.assign(new Error('too_large'), { status: 413 })) : resolve(Buffer.concat(chunks))));
    req.on('error', reject);
  });
}

const reply = (res, status, obj) => {
  if (res.headersSent) return;
  const body = obj === undefined ? '' : JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  res.end(body);
};

/**
 * node:http 处理器:(req, res) => Promise<void>。只收 POST。
 * onEvent(event, payload, envelope) 在 200 之后异步调用(Zoom 要求 3 s 内响应),异常只记日志。
 */
export function createWebhookHandler({ secret, onEvent = () => {}, log = () => {}, now = () => Date.now(), maxBytes = MAX_BODY_BYTES, toleranceSec = TOLERANCE_SEC } = {}) {
  if (!secret) throw new TypeError('createWebhookHandler: secret required');
  return async function handle(req, res) {
    if (req.method !== 'POST') { res.setHeader('allow', 'POST'); return reply(res, 405, { error: 'method_not_allowed' }); }
    let raw;
    try { raw = await readBody(req, maxBytes); } catch (e) { return reply(res, e.status ?? 400, { error: e.message }); }
    const v = verifyWebhook({ secret, headers: req.headers, rawBody: raw, now: now(), toleranceSec });
    if (!v.ok) { log(`webhook rejected: ${v.code}`); return reply(res, 401, { error: v.code }); }
    let env;
    try { env = JSON.parse(raw.toString('utf8')); } catch { return reply(res, 400, { error: 'bad_json' }); }
    const event = typeof env?.event === 'string' ? env.event : '';
    const payload = env?.payload && typeof env.payload === 'object' ? env.payload : {};
    if (event === 'endpoint.url_validation') {
      if (typeof payload.plainToken !== 'string' || !payload.plainToken) return reply(res, 400, { error: 'bad_plain_token' });
      return reply(res, 200, urlValidationResponse(secret, payload.plainToken));
    }
    reply(res, 200, { ok: true });
    if (!RTMS_EVENTS.includes(event)) { log(`webhook ignored: ${event || '(none)'}`); return; }
    try { await onEvent(event, payload, env); } catch (e) { log(`webhook handler error (${event}): ${e?.message ?? e}`); }
  };
}

/// rtms_started 的 server_urls 是字符串(多个以逗号分隔);规整成数组
export const splitServerUrls = (s) => (Array.isArray(s) ? s : String(s ?? '').split(',')).map((x) => String(x).trim()).filter(Boolean);
