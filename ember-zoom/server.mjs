// ember-zoom · 一个 node:http 服务器同时承载:
//   POST /webhook           Zoom webhook(webhook.mjs)
//   GET  /sidebar/…         Zoom App 侧边栏静态页(OWASP 头:Zoom Apps 要求 CSP、HSTS、X-Content-Type-Options、Referrer-Policy)
//   GET  /healthz           {ok:true}(不含任何会议信息)
//   WS   /hub               侧边栏 hub(hub.mjs)
import http from 'node:http';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createWebhookHandler } from './webhook.mjs';
import { SidebarHub } from './hub.mjs';

export const SIDEBAR_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'sidebar');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };
export const ZOOM_SDK_ORIGIN = 'https://appssdk.zoom.us';

/// Zoom Apps 必需的 OWASP 安全头(https://developers.zoom.us/docs/zoom-apps/security/owasp/)。
/// connect-src 显式列出同主机的 wss://(老浏览器的 'self' 不含 ws/wss)。
export function securityHeaders(host) {
  const h = String(host ?? '').replace(/[^A-Za-z0-9.:\-[\]]/g, '');
  const ws = h ? ` wss://${h} ws://${h}` : '';
  return {
    'content-security-policy': [
      "default-src 'self'", `script-src 'self' ${ZOOM_SDK_ORIGIN}`, "style-src 'self'", "img-src 'self' data:",
      `connect-src 'self'${ws}`, "object-src 'none'", "base-uri 'self'", "form-action 'self'",
    ].join('; '),
    'strict-transport-security': 'max-age=31536000; includeSubDomains',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'same-origin',
    'cache-control': 'no-store',
  };
}

async function serveStatic(req, res, rel) {
  const safe = path.normalize(rel).replace(/^([/\\])+/, '');
  if (!safe || safe.includes('..')) return false;
  const file = path.join(SIDEBAR_DIR, safe);
  if (!file.startsWith(SIDEBAR_DIR + path.sep)) return false;
  let body;
  try { body = await readFile(file); } catch { return false; }
  res.writeHead(200, { 'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream', ...securityHeaders(req.headers.host) });
  res.end(req.method === 'HEAD' ? undefined : body);
  return true;
}

/**
 * @returns {{server: http.Server, hub: SidebarHub, listen(port, host): Promise<number>, close(): Promise<void>}}
 */
export function createZoomServer({ webhookSecret, onWebhook, log = () => {}, allowOrigins = null, now } = {}) {
  const hub = new SidebarHub({ log, allowOrigins });
  const webhook = createWebhookHandler({ secret: webhookSecret, onEvent: onWebhook, log, ...(now ? { now } : {}) });
  const server = http.createServer(async (req, res) => {
    let pathname = '/';
    try { pathname = new URL(req.url, 'http://x').pathname; } catch { /* */ }
    try {
      if (pathname === '/webhook') return await webhook(req, res);
      if (pathname === '/healthz') { res.writeHead(200, { 'content-type': 'application/json', ...securityHeaders(req.headers.host) }); return res.end('{"ok":true}'); }
      if (req.method === 'GET' || req.method === 'HEAD') {
        if (pathname === '/' || pathname === '/sidebar') { res.writeHead(302, { location: '/sidebar/', ...securityHeaders(req.headers.host) }); return res.end(); }
        if (pathname.startsWith('/sidebar/')) {
          const rel = pathname === '/sidebar/' ? 'index.html' : decodeURIComponent(pathname.slice('/sidebar/'.length));
          if (await serveStatic(req, res, rel)) return undefined;
        }
      }
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8', ...securityHeaders(req.headers.host) });
      return res.end('not found');
    } catch (e) {
      log(`http error: ${e?.message ?? e}`);
      if (!res.headersSent) res.writeHead(500, securityHeaders(req.headers.host));
      return res.end();
    }
  });
  server.on('upgrade', (req, socket, head) => hub.handleUpgrade(req, socket, head));
  return {
    server, hub,
    listen(port = 0, host = '127.0.0.1') {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => { server.off('error', reject); resolve(server.address().port); });
      });
    },
    close() {
      hub.close();
      server.closeAllConnections?.();
      return new Promise((r) => server.close(() => r()));
    },
  };
}
