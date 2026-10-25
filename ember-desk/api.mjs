// ember-desk · 本机 HTTP API(只听 127.0.0.1,随机端口)。
//   所有端点(/ui 除外)要求 Authorization: Bearer <token>(timingSafeEqual 比较)→ 否则 401 {error:"unauthorized"}
//   Host 头必须是 127.0.0.1:<port> 或 localhost:<port>(防 DNS rebinding)→ 否则 403
//   POST 体上限 64 KB,只收 application/json(空体可不带 Content-Type)
//   GET /events = SSE(event/data),15 s 心跳注释行
import http from 'node:http';
import { timingSafeEqual, createHash } from 'node:crypto';
import { UI_HTML } from './ui.mjs';

export const BODY_LIMIT = 64 * 1024;
export const HEARTBEAT_MS = 15_000;

class HttpError extends Error { constructor(status, error, message) { super(message ?? error); this.status = status; this.error = error; } }

const digest = (s) => createHash('sha256').update(String(s)).digest();
export function tokenOk(header, token) {
  const m = /^Bearer\s+(\S+)$/i.exec(String(header ?? ''));
  if (!m || !token) return false;
  return timingSafeEqual(digest(m[1]), digest(token)); // 定长比较,长度不泄露
}

export function hostOk(host, port) {
  const h = String(host ?? '').toLowerCase();
  return h === `127.0.0.1:${port}` || h === `localhost:${port}`;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const len = Number(req.headers['content-length'] ?? 0);
    if (len > BODY_LIMIT) { reject(new HttpError(413, 'body_too_large')); req.resume(); return; }
    const chunks = [];
    let n = 0;
    req.on('data', (d) => {
      n += d.length;
      if (n > BODY_LIMIT) { reject(new HttpError(413, 'body_too_large')); req.destroy(); return; }
      chunks.push(d);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function jsonBody(req) {
  const raw = await readBody(req);
  const ct = String(req.headers['content-type'] ?? '').toLowerCase();
  if (!raw.trim()) {
    if (ct && !/^application\/json\b/.test(ct)) throw new HttpError(415, 'unsupported_media_type', 'Content-Type 必须是 application/json');
    return {};
  }
  if (!/^application\/json\b/.test(ct)) throw new HttpError(415, 'unsupported_media_type', 'Content-Type 必须是 application/json');
  let o;
  try { o = JSON.parse(raw); } catch { throw new HttpError(400, 'bad_json', '请求体不是合法 JSON'); }
  if (!o || typeof o !== 'object' || Array.isArray(o)) throw new HttpError(400, 'bad_json', '请求体必须是 JSON 对象');
  return o;
}

const SEC_HEADERS = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' };

function send(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { ...SEC_HEADERS, 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

/**
 * app: { status(), join(body), leave(), channels(), startChannel(id), stopChannel(id), ask(text), speak(text), feed(n), quit(), subscribe(fn) → unsubscribe }
 * 返回 { server, listen(port) → Promise<port>, close(), port }
 */
export function createApiServer({ token, app, log = () => {}, host = '127.0.0.1' }) {
  const sse = new Set();
  let port = 0;

  const server = http.createServer(async (req, res) => {
    try {
      if (!hostOk(req.headers.host, port)) throw new HttpError(403, 'bad_host');
      const u = new URL(req.url, `http://127.0.0.1:${port}`);
      const p = u.pathname;
      const m = req.method;
      if (m === 'GET' && (p === '/ui' || p === '/ui/')) {
        res.writeHead(200, { ...SEC_HEADERS, 'content-type': 'text/html; charset=utf-8', 'x-frame-options': 'DENY', 'content-security-policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" });
        res.end(UI_HTML);
        return;
      }
      if (!tokenOk(req.headers.authorization, token)) throw new HttpError(401, 'unauthorized');
      if (m === 'GET' && p === '/status') return send(res, 200, await app.status());
      if (m === 'GET' && p === '/channels') return send(res, 200, await app.channels());
      if (m === 'GET' && p === '/feed') {
        const n = Math.max(1, Math.min(500, Number.parseInt(u.searchParams.get('n') ?? '20', 10) || 20));
        return send(res, 200, await app.feed(n));
      }
      if (m === 'GET' && p === '/events') {
        res.writeHead(200, { ...SEC_HEADERS, 'content-type': 'text/event-stream; charset=utf-8', connection: 'keep-alive' });
        res.write(': ok\n\n');
        const write = (type, data) => { try { res.write(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`); } catch { /* */ } };
        write('status', await app.status());
        const unsub = app.subscribe(write);
        const hb = setInterval(() => { try { res.write(': hb\n\n'); } catch { /* */ } }, HEARTBEAT_MS);
        hb.unref?.();
        const client = { res, close: () => { clearInterval(hb); unsub(); try { res.end(); } catch { /* */ } } };
        sse.add(client);
        req.on('close', () => { clearInterval(hb); unsub(); sse.delete(client); });
        return undefined;
      }
      if (m === 'POST') {
        const body = await jsonBody(req);
        if (p === '/join') return send(res, 200, await app.join(body));
        if (p === '/leave') return send(res, 200, await app.leave());
        if (p === '/ask') return send(res, 200, await app.ask(body.text));
        if (p === '/speak') return send(res, 200, await app.speak(body.text));
        if (p === '/quit') { send(res, 200, { ok: true }); setImmediate(() => app.quit()); return undefined; }
        const cm = p.match(/^\/channels\/([a-z][a-z0-9-]{0,31})\/(start|stop)$/);
        if (cm) return send(res, 200, cm[2] === 'start' ? await app.startChannel(cm[1]) : await app.stopChannel(cm[1]));
      }
      throw new HttpError(404, 'not_found');
    } catch (e) {
      const status = Number.isInteger(e.status) ? e.status : 500;
      if (status >= 500) log(`api ${req.method} ${req.url?.split('?')[0]} error: ${e.message}`);
      if (!res.headersSent) send(res, status, { error: e.error ?? e.code ?? (status >= 500 ? 'internal' : 'bad_request'), message: status >= 500 ? '内部错误' : e.message });
      else try { res.end(); } catch { /* */ }
    }
  });
  server.headersTimeout = 10_000;
  server.requestTimeout = 120_000;

  return {
    server,
    get port() { return port; },
    listen(want = 0) {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(want, host, () => { port = server.address().port; resolve(port); });
      });
    },
    close() {
      for (const c of sse) c.close();
      sse.clear();
      return new Promise((r) => { server.close(() => r()); server.closeAllConnections?.(); });
    },
  };
}
