// 极简静态服务器:托管 app/build/web 用于本机联调
// 用法:node tool/serve_web.mjs [port]
import http from 'node:http';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = normalize(join(fileURLToPath(import.meta.url), '..', '..', 'build', 'web'));
const port = Number(process.argv[2] ?? 8080);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml',
  '.map': 'application/json',
  '.woff2': 'font/woff2',
};

http
  .createServer((req, res) => {
    let path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (path === '/') path = '/index.html';
    let file = normalize(join(root, path));
    if (!file.startsWith(root)) {
      res.writeHead(403);
      return res.end();
    }
    if (!existsSync(file) || !statSync(file).isFile()) {
      // SPA 回退
      file = join(root, 'index.html');
    }
    // 缓存策略:仅内容稳定的资源(canvaskit/字体)长缓存;
    // 应用产物(html/js/mjs/wasm)每次构建都变,必须 no-cache(血泪教训)
    const name = file.split(/[\\/]/).pop() ?? '';
    const isStable = file.includes('canvaskit') || /\.(otf|ttf|woff2?)$/.test(name);
    const cacheControl = isStable
      ? 'public, max-age=31536000, immutable'
      : 'no-cache';
    res.writeHead(200, {
      'content-type': MIME[extname(file)] ?? 'application/octet-stream',
      'cache-control': cacheControl,
      // WASM skwasm 多线程 + SharedArrayBuffer 需要跨源隔离
      'cross-origin-opener-policy': 'same-origin',
      'cross-origin-embedder-policy': 'require-corp',
    });
    createReadStream(file).pipe(res);
  })
  .listen(port, () => console.log(`[serve] http://127.0.0.1:${port} -> ${root}`));
