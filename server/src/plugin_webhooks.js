// 插件 webhook:SSRF 守卫 + manifest 抓取 + 签名投递队列(契约 docs/plans/plugin-focus-contract.md §1 / §5)。
//
// SSRF 纪律:
// - 只认 https(LARES_PLUGIN_ALLOW_PRIVATE=1 时放开 http 与私网,只给测试/自建内网用);
// - 先 DNS 解析(dns.promises.lookup all:true),任何一个地址落在私网/回环/链路本地/CGNAT/ULA/组播/
//   未指定/IPv4-mapped 上述地址 → 拒绝;
// - 连接时用自定义 lookup 把已校验的 IP 钉死,DNS rebinding 换不了地址;
// - 不跟随重定向(3xx 一律当失败)。
// 安装时与每次投递时都重新校验。

import crypto from 'node:crypto';
import dns from 'node:dns';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';

export const MANIFEST_FETCH_MAX = 16 * 1024;
export const FETCH_TIMEOUT_MS = 5000;
export const QUEUE_MAX = 100;
export const MAX_ATTEMPTS = 4;

class WebhookError extends Error {
  constructor(reason, detail) {
    super(detail ? `${reason}: ${detail}` : reason);
    this.reason = reason;
    this.detail = detail;
  }
}

// ── 地址黑名单 ───────────────────────────────────────────────────────────
const blocked = new net.BlockList();
for (const [a, p] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15],
  ['198.51.100.0', 24], ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
]) blocked.addSubnet(a, p, 'ipv4');
for (const [a, p] of [
  ['::', 128], ['::1', 128], ['fe80::', 10], ['fc00::', 7], ['ff00::', 8], ['64:ff9b::', 96], ['2001:db8::', 32], ['100::', 64],
]) blocked.addSubnet(a, p, 'ipv6');

/// 该 IP 是否不允许连(私网 / 回环 / …)。解析不了的一律当不允许。
export function isBlockedIp(ip) {
  let a = String(ip ?? '').trim().toLowerCase();
  if (a.startsWith('[') && a.endsWith(']')) a = a.slice(1, -1);
  const zone = a.indexOf('%');
  if (zone >= 0) a = a.slice(0, zone);
  const fam = net.isIP(a);
  if (fam === 4) return blocked.check(a, 'ipv4');
  if (fam === 6) {
    // IPv4-mapped(::ffff:a.b.c.d / ::ffff:hhhh:hhhh)与 IPv4-compatible(::a.b.c.d):按里面的 v4 判
    const v4 = embeddedV4(a);
    if (v4) return blocked.check(v4, 'ipv4');
    return blocked.check(a, 'ipv6');
  }
  return true;
}

/// 从 IPv6 字面量里取出嵌入的 IPv4(mapped / compatible),否则 null
function embeddedV4(a) {
  // 展开成 8 组
  let groups;
  try {
    groups = expandV6(a);
  } catch { return null; }
  if (!groups) return null;
  const top = groups.slice(0, 5).every((g) => g === 0);
  if (!top) return null;
  if (groups[5] !== 0xffff && groups[5] !== 0) return null;
  if (groups[5] === 0 && groups[6] === 0) return null; // :: 与 ::1 走 v6 规则
  const hi = groups[6], lo = groups[7];
  return `${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`;
}

function expandV6(a) {
  let s = a;
  const tailV4 = /(\d+\.\d+\.\d+\.\d+)$/.exec(s);
  if (tailV4) {
    const p = tailV4[1].split('.').map(Number);
    s = s.slice(0, -tailV4[1].length) + `${((p[0] << 8) | p[1]).toString(16)}:${((p[2] << 8) | p[3]).toString(16)}`;
  }
  const parts = s.split('::');
  if (parts.length > 2) return null;
  const head = parts[0] ? parts[0].split(':') : [];
  const tail = parts.length === 2 && parts[1] ? parts[1].split(':') : [];
  const fill = parts.length === 2 ? 8 - head.length - tail.length : 0;
  const all = [...head, ...Array(Math.max(0, fill)).fill('0'), ...tail];
  if (all.length !== 8) return null;
  return all.map((g) => parseInt(g || '0', 16));
}

export function allowPrivateFrom(env = process.env) {
  return String(env.LARES_PLUGIN_ALLOW_PRIVATE ?? '') === '1';
}

/// 校验 URL 并解析出一个可连的地址。失败抛 WebhookError('ssrf_blocked'|'bad_url')。
export async function resolveSafe(rawUrl, { allowPrivate = false, lookup = dns.promises.lookup } = {}) {
  let u;
  try { u = new URL(rawUrl); } catch { throw new WebhookError('bad_url'); }
  if (u.protocol !== 'https:' && !(allowPrivate && u.protocol === 'http:')) throw new WebhookError('ssrf_blocked', 'scheme');
  if (u.username || u.password) throw new WebhookError('ssrf_blocked', 'userinfo');
  let host = u.hostname;
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
  if (!host) throw new WebhookError('bad_url');
  let addrs;
  if (net.isIP(host)) addrs = [{ address: host, family: net.isIP(host) }];
  else {
    try {
      addrs = await lookup(host, { all: true, verbatim: true });
    } catch (e) {
      throw new WebhookError('ssrf_blocked', `dns: ${e?.code ?? e?.message}`);
    }
  }
  if (!Array.isArray(addrs) || addrs.length === 0) throw new WebhookError('ssrf_blocked', 'dns_empty');
  if (!allowPrivate) {
    for (const a of addrs) if (isBlockedIp(a.address)) throw new WebhookError('ssrf_blocked', `address ${a.address}`);
  }
  return { url: u, host, address: addrs[0].address, family: addrs[0].family };
}

/// 发一个请求到已校验的地址(钉 IP、不跟随重定向、超时、响应体上限)
function pinnedRequest(target, { method = 'GET', headers = {}, body = null, timeoutMs = FETCH_TIMEOUT_MS, maxBytes = 64 * 1024 } = {}) {
  return new Promise((resolve, reject) => {
    const { url, address, family } = target;
    const mod = url.protocol === 'https:' ? https : http;
    const pinnedLookup = (_hostname, opts, cb) => {
      if (typeof opts === 'function') { cb = opts; opts = {}; }
      if (opts && opts.all) cb(null, [{ address, family }]);
      else cb(null, address, family);
    };
    let done = false;
    const finish = (fn, v) => { if (!done) { done = true; clearTimeout(timer); fn(v); } };
    const req = mod.request({
      protocol: url.protocol,
      hostname: target.host,
      port: url.port || undefined,
      path: `${url.pathname}${url.search}`,
      method,
      headers: { 'user-agent': 'Lares-Plugin/1', ...headers },
      lookup: pinnedLookup,
      agent: false,
      servername: net.isIP(target.host) ? undefined : target.host,
    }, (res) => {
      const chunks = [];
      let size = 0;
      res.on('data', (c) => {
        size += c.length;
        if (size > maxBytes) { finish(reject, new WebhookError('too_large')); res.destroy(); return; }
        chunks.push(c);
      });
      res.on('end', () => finish(resolve, { status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      res.on('error', (e) => finish(reject, e));
    });
    const timer = setTimeout(() => { req.destroy(new WebhookError('timeout')); finish(reject, new WebhookError('timeout')); }, timeoutMs);
    req.on('error', (e) => finish(reject, e));
    if (body) req.write(body);
    req.end();
  });
}

/// 抓 manifestUrl:https、SSRF 守卫、≤16 KB、5 s、不跟随重定向。返回解析好的对象。
export async function fetchManifest(rawUrl, { allowPrivate = false, lookup } = {}) {
  const target = await resolveSafe(rawUrl, { allowPrivate, lookup }); // 抛 ssrf_blocked / bad_url
  let res;
  try {
    res = await pinnedRequest(target, { headers: { accept: 'application/json' }, maxBytes: MANIFEST_FETCH_MAX });
  } catch (e) {
    throw new WebhookError('manifest_fetch_failed', e?.reason ?? e?.code ?? e?.message);
  }
  if (res.status !== 200) throw new WebhookError('manifest_fetch_failed', `status ${res.status}`);
  try {
    return JSON.parse(res.body.toString('utf8'));
  } catch {
    throw new WebhookError('manifest_fetch_failed', 'bad_json');
  }
}

// ── 签名 ─────────────────────────────────────────────────────────────────
export function newWebhookSecret() {
  return `whsec_${crypto.randomBytes(32).toString('base64url')}`;
}

export function sign(secret, ts, body) {
  return `v1=${crypto.createHmac('sha256', secret).update(`${ts}.${body}`, 'utf8').digest('hex')}`;
}

/// 接收方用:校验 X-Lares-Signature。ts 为 X-Lares-Timestamp(秒),body 为原始请求体字符串。
export function verifySignature(secret, ts, body, header, { toleranceSec = 300, nowSec = Math.floor(Date.now() / 1000) } = {}) {
  const t = Number(ts);
  if (!Number.isFinite(t) || Math.abs(nowSec - t) > toleranceSec) return false;
  const expect = Buffer.from(sign(secret, String(ts), typeof body === 'string' ? body : Buffer.from(body).toString('utf8')));
  const got = Buffer.from(String(header ?? ''));
  return expect.length === got.length && crypto.timingSafeEqual(expect, got);
}

// ── 投递队列 ─────────────────────────────────────────────────────────────
/**
 * @param {object} [o]
 * @param {object} [o.env]
 * @param {Function} [o.lookup]  测试可注入
 * @param {object} [o.log]
 */
export function createWebhookDispatcher({ env = process.env, lookup, log = console } = {}) {
  const allowPrivate = allowPrivateFrom(env);
  const baseMs = Number(env.LARES_PLUGIN_RETRY_BASE_MS ?? 1000);
  const timeoutMs = Number(env.LARES_PLUGIN_WEBHOOK_TIMEOUT_MS ?? FETCH_TIMEOUT_MS);
  /** @type {Map<string, {items:Array, running:boolean}>} */
  const queues = new Map();
  const stats = { delivered: 0, failed: 0, dropped: 0, attempts: 0 };
  const timers = new Set();
  let closed = false;

  const sleep = (ms) => new Promise((r) => { const t = setTimeout(() => { timers.delete(t); r(); }, ms); timers.add(t); });

  async function attempt(job) {
    const target = await resolveSafe(job.url, { allowPrivate, lookup });
    const ts = Math.floor(Date.now() / 1000);
    const res = await pinnedRequest(target, {
      method: 'POST',
      timeoutMs,
      maxBytes: 64 * 1024,
      body: job.body,
      headers: {
        'content-type': 'application/json',
        'content-length': String(Buffer.byteLength(job.body)),
        'x-lares-event': job.type,
        'x-lares-delivery': job.id,
        'x-lares-timestamp': String(ts),
        'x-lares-signature': sign(job.secret, ts, job.body),
      },
    });
    if (res.status < 200 || res.status >= 300) throw new WebhookError('http_status', String(res.status));
  }

  async function run(key) {
    const q = queues.get(key);
    if (!q || q.running) return;
    q.running = true;
    try {
      while (q.items.length && !closed) {
        const job = q.items.shift();
        let ok = false;
        for (let n = 0; n < MAX_ATTEMPTS && !closed; n++) {
          stats.attempts += 1;
          try {
            await attempt(job);
            ok = true;
            break;
          } catch (e) {
            if (n < MAX_ATTEMPTS - 1) await sleep(baseMs * 4 ** n);
            else log.error?.(`[plugin] webhook 投递失败 ${job.pluginId} ${job.type} ${job.id}:`, e?.reason ?? e?.code ?? e?.message);
          }
        }
        if (ok) stats.delivered += 1; else stats.failed += 1;
      }
    } finally {
      q.running = false;
      if (q.items.length === 0) queues.delete(key);
    }
  }

  /// 入队一条事件。job: {key, url, secret, type, circleId, pluginId, data}
  function enqueue({ key, url, secret, type, circleId, pluginId, data }) {
    if (closed || !url || !secret) return null;
    const id = `evt_${crypto.randomBytes(12).toString('hex')}`;
    const body = JSON.stringify({ id, type, circleId, pluginId, ts: Date.now(), data: data ?? {} });
    let q = queues.get(key);
    if (!q) { q = { items: [], running: false }; queues.set(key, q); }
    while (q.items.length >= QUEUE_MAX) {
      const gone = q.items.shift();
      stats.dropped += 1;
      log.warn?.(`[plugin] webhook 队列满,丢弃最旧事件 ${gone.pluginId} ${gone.type} ${gone.id}`);
    }
    q.items.push({ id, url, secret, type, pluginId, body });
    run(key);
    return id;
  }

  /// 丢掉某安装还没投出去的事件(解散圈子用;卸载时 uninstalled 要先投,不调这个)
  function drop(key) {
    const q = queues.get(key);
    if (q) q.items.length = 0;
  }

  function close() {
    closed = true;
    for (const t of timers) clearTimeout(t);
    timers.clear();
  }

  return { enqueue, drop, close, stats, allowPrivate };
}

export { WebhookError };
