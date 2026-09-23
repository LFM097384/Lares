// APNs(Apple 推送)发送端:HTTP/2 + ES256 provider token(.p8 钥匙)。
//
// 为什么自己写而不用 apn / node-apn 之类的包:服务端刻意只有三个依赖
// (hash-wasm / livekit-server-sdk / ws),而 APNs 协议本身很小 ——
// 一个 JWT、一个 HTTP/2 POST。Node 自带 http2 与 crypto 足够。
//
// 用法:
//   const apns = createApnsSender({ env: process.env, log: console });
//   if (apns.enabled) await apns.send(token, 'sandbox' | 'production', payload, headers);
//   // send 永不 reject,只返回 { status, reason? };status 0 = 网络层失败
//
// 环境变量:
//   LARES_APNS_KEY          .p8 的 PEM 全文;或 PEM 的 base64(不含 "-----BEGIN" 即按 base64 解)
//   LARES_APNS_KEY_FILE     或者给 .p8 文件路径(与上面二选一,LARES_APNS_KEY 优先)
//   LARES_APNS_KEY_ID       Apple 开发者后台 Keys 页面的 10 位 Key ID
//   LARES_APNS_TEAM_ID      Team ID(Lares 为 7CH28564U7)
//   LARES_APNS_TOPIC        bundle id,默认 com.lfm097384.lares
//   LARES_APNS_HOST_OVERRIDE  仅测试:形如 https://127.0.0.1:12345,sandbox/production 都打到这里
//   LARES_APNS_INSECURE_TLS   仅测试:=1 且设了 HOST_OVERRIDE 时才接受自签证书;
//                             没有 HOST_OVERRIDE 时此项被忽略 —— 绝不对真 Apple 主机关证书校验。

import http2 from 'node:http2';
import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';

const HOSTS = {
  sandbox: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
};

// Apple 的要求:provider token 刷新不能快于 20 分钟一次(否则 TooManyProviderTokenUpdates),
// 也不能老于 60 分钟(否则 ExpiredProviderToken)。取 40 分钟,两头都有余量。
const JWT_TTL_MS = 40 * 60_000;
const REQUEST_TIMEOUT_MS = 10_000;

const b64url = (buf) => Buffer.from(buf).toString('base64')
  .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

/// 把 env 里的钥匙读成 KeyObject。失败返回 { error }。
function loadKey(env) {
  let pem = '';
  if (env.LARES_APNS_KEY) {
    const raw = String(env.LARES_APNS_KEY).trim();
    // 允许 base64 形态:docker/.env 和 systemd EnvironmentFile 都不好放多行值
    pem = raw.includes('-----BEGIN') ? raw : Buffer.from(raw, 'base64').toString('utf8');
    // 有些面板会把换行存成字面 \n
    pem = pem.replace(/\\n/g, '\n');
  } else if (env.LARES_APNS_KEY_FILE) {
    try {
      pem = readFileSync(env.LARES_APNS_KEY_FILE, 'utf8');
    } catch (e) {
      return { error: `读不了 LARES_APNS_KEY_FILE(${env.LARES_APNS_KEY_FILE}):${e.message}` };
    }
  } else {
    return { missing: true };
  }
  try {
    const key = crypto.createPrivateKey(pem);
    // APNs 只收 ES256(P-256);给错成 RSA 钥匙时在启动期就说清楚,而不是每条推送都 403
    if (key.asymmetricKeyType !== 'ec') return { error: `钥匙类型是 ${key.asymmetricKeyType},APNs 需要 EC P-256(.p8)` };
    return { key };
  } catch (e) {
    return { error: `钥匙解析失败:${e.message}` };
  }
}

export function createApnsSender({ env = process.env, log = console } = {}) {
  const keyId = String(env.LARES_APNS_KEY_ID ?? '').trim();
  const teamId = String(env.LARES_APNS_TEAM_ID ?? '').trim();
  const topic = String(env.LARES_APNS_TOPIC ?? '').trim() || 'com.lfm097384.lares';
  const override = String(env.LARES_APNS_HOST_OVERRIDE ?? '').trim();
  const insecure = Boolean(override) && env.LARES_APNS_INSECURE_TLS === '1';

  const disabled = (reason) => ({
    enabled: false,
    reason,
    topic,
    send: async () => ({ status: 0, reason: 'disabled' }),
    close: () => {},
  });

  const k = loadKey(env);
  // 完全没配钥匙 = 本来就没打算开推送(本地开发/自建),安静地禁用,由调用方打一行提示
  if (k.missing) return disabled('not_configured');
  if (k.error) {
    // 配了却配坏了:只在这里说一次,之后所有推送静默 no-op(不刷屏)
    log.error(`[push] APNs 钥匙无效,推送已禁用:${k.error}`);
    return disabled('bad_key');
  }
  if (!keyId || !teamId) {
    log.error('[push] 给了 APNs 钥匙但缺 LARES_APNS_KEY_ID / LARES_APNS_TEAM_ID,推送已禁用');
    return disabled('not_configured');
  }
  const key = k.key;

  // 启动期试签一次:钥匙能解析但签不了(极少见)也在这里暴露,而不是第一条推送时
  try {
    crypto.sign('sha256', Buffer.from('probe'), { key, dsaEncoding: 'ieee-p1363' });
  } catch (e) {
    log.error(`[push] APNs 钥匙无法签名,推送已禁用:${e.message}`);
    return disabled('bad_key');
  }

  let jwt = null;
  let jwtAt = 0;
  function providerToken() {
    const now = Date.now();
    if (jwt && now - jwtAt < JWT_TTL_MS) return jwt;
    const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
    const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) }));
    const input = `${header}.${claims}`;
    // JWS 的 ES256 要的是 r||s 定长 64 字节,不是 DER —— 所以必须 ieee-p1363
    const sig = crypto.sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' });
    jwt = `${input}.${b64url(sig)}`;
    jwtAt = now;
    return jwt;
  }

  // 每个主机一条 HTTP/2 长连接,按需建立。APNs 明确要求复用连接,
  // 频繁新建会被当成 DoS 拒掉。连接一出事(close/error/goaway)就丢掉缓存,下次重连。
  const sessions = new Map(); // origin -> ClientHttp2Session
  function sessionFor(origin) {
    const cached = sessions.get(origin);
    if (cached && !cached.closed && !cached.destroyed) return cached;
    const s = http2.connect(origin, insecure ? { rejectUnauthorized: false } : {});
    const drop = () => { if (sessions.get(origin) === s) sessions.delete(origin); };
    s.on('error', (e) => { drop(); log.error(`[push] APNs 连接错误(${origin}):${e.message}`); });
    s.on('close', drop);
    s.on('goaway', () => { drop(); try { s.close(); } catch { /* 已关 */ } });
    // 推送连接不该把进程拴住(测试/优雅退出时)
    s.unref();
    sessions.set(origin, s);
    return s;
  }

  function send(token, envName, payload, headers = {}) {
    return new Promise((resolve) => {
      let done = false;
      const finish = (r) => { if (!done) { done = true; resolve(r); } };
      try {
        const origin = override || HOSTS[envName] || HOSTS.production;
        const s = sessionFor(origin);
        const body = Buffer.from(JSON.stringify(payload));
        const req = s.request({
          ':method': 'POST',
          ':path': `/3/device/${token}`,
          authorization: `bearer ${providerToken()}`,
          'apns-topic': topic,
          'content-type': 'application/json',
          'content-length': body.length,
          ...headers,
        });
        req.setTimeout(REQUEST_TIMEOUT_MS, () => {
          req.close(http2.constants.NGHTTP2_CANCEL);
          finish({ status: 0, reason: 'timeout' });
        });
        let status = 0;
        const chunks = [];
        req.on('response', (h) => { status = Number(h[':status']) || 0; });
        req.on('data', (c) => chunks.push(c));
        req.on('end', () => {
          let reason;
          if (chunks.length) {
            try { reason = JSON.parse(Buffer.concat(chunks).toString('utf8')).reason; } catch { /* 非 JSON */ }
          }
          // provider token 失效:丢掉缓存,下一条推送重签(本条不重试,避免放大)
          if (status === 403 && (reason === 'ExpiredProviderToken' || reason === 'InvalidProviderToken')) {
            jwt = null;
          }
          finish({ status, ...(reason ? { reason } : {}) });
        });
        req.on('error', (e) => finish({ status: 0, reason: e.message }));
        req.end(body);
      } catch (e) {
        finish({ status: 0, reason: e?.message ?? String(e) });
      }
    });
  }

  function close() {
    for (const s of sessions.values()) { try { s.close(); } catch { /* 已关 */ } }
    sessions.clear();
  }

  return { enabled: true, topic, send, close };
}

/// 这条回执是否意味着「这个设备 token 作废了,该删订阅」
export function isInvalidTokenResponse(r) {
  if (!r) return false;
  if (r.status === 410) return true;
  return r.status === 400 && (r.reason === 'BadDeviceToken' || r.reason === 'DeviceTokenNotForTopic');
}
