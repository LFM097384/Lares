// Lares 插件 webhook 接收端示例(Node ≥ 18,无依赖)。
//
//   $env:LARES_WEBHOOK_SECRET = 'whsec_…'; node webhook-receiver.mjs      # PowerShell
//   LARES_WEBHOOK_SECRET=whsec_… PORT=8788 node webhook-receiver.mjs       # bash
//
// 任何路径都接受 POST。签名对 → 200;不对 / 过期 → 401。格式见 docs/plugin-api.md §5。
import http from 'node:http';
import crypto from 'node:crypto';

const SECRET = process.env.LARES_WEBHOOK_SECRET;
const PORT = Number(process.env.PORT || 8788);
const WINDOW_SEC = 300;
const MAX_BODY = 1 << 20; // 1 MB

if (!SECRET) {
  console.error('请设置环境变量 LARES_WEBHOOK_SECRET(安装插件时拿到的 whsec_…)');
  process.exit(1);
}

/** 校验 X-Lares-Signature。raw 必须是原始请求体字节。 */
function verify(headers, raw) {
  const ts = String(headers['x-lares-timestamp'] || '');
  const sig = String(headers['x-lares-signature'] || '');
  if (!/^\d+$/.test(ts)) return 'missing_timestamp';
  if (!sig.startsWith('v1=')) return 'missing_signature';
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(ts)) > WINDOW_SEC) return 'stale_timestamp';
  const expected = crypto.createHmac('sha256', SECRET).update(`${ts}.`).update(raw).digest();
  const hex = sig.slice(3);
  if (!/^[0-9a-f]+$/i.test(hex)) return 'bad_signature';
  const got = Buffer.from(hex, 'hex');
  if (got.length !== expected.length || !crypto.timingSafeEqual(got, expected)) return 'bad_signature';
  return null;
}

const seen = new Set(); // 简单去重:X-Lares-Delivery

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405, { allow: 'POST' }).end();
    return;
  }
  const chunks = [];
  let size = 0;
  let tooBig = false;
  req.on('data', (c) => {
    size += c.length;
    if (size > MAX_BODY) { tooBig = true; return; }
    chunks.push(c);
  });
  req.on('end', () => {
    if (tooBig) { res.writeHead(413).end('too large'); return; }
    const raw = Buffer.concat(chunks);
    const err = verify(req.headers, raw);
    if (err) {
      console.warn(new Date().toISOString(), 'rejected', req.url, err);
      res.writeHead(401, { 'content-type': 'text/plain' }).end(err);
      return;
    }
    let evt;
    try { evt = JSON.parse(raw.toString('utf8')); } catch {
      res.writeHead(400).end('bad json');
      return;
    }
    const delivery = req.headers['x-lares-delivery'] || evt.id;
    if (seen.has(delivery)) {
      res.writeHead(200).end('duplicate');
      return;
    }
    seen.add(delivery);
    if (seen.size > 1000) seen.delete(seen.values().next().value);

    console.log(new Date().toISOString(), evt.type, evt.circleId, evt.pluginId, JSON.stringify(evt.data));
    switch (evt.type) {
      case 'installed':
        // evt.data.token 是插件 token(plg_…),生产中应存进密钥库,用它调 /api/v1。
        console.log('  收到插件 token(已隐藏):', String(evt.data?.token || '').slice(0, 8) + '…');
        break;
      case 'uninstalled':
        console.log('  插件被卸载,token 已失效');
        break;
      default:
        break;
    }
    res.writeHead(200, { 'content-type': 'text/plain' }).end('ok');
  });
});

server.listen(PORT, () => console.log(`Lares webhook receiver listening on :${PORT}`));
