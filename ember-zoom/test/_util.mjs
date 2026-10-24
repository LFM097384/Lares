// ember-zoom 测试小工具:侧边栏 WS 客户端替身 + until。
import { WebSocket } from '../deps.mjs';

export const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
export async function until(fn, ms = 5000, what = 'condition') {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() - t0 > ms) throw new Error(`until: timed out (${what})`);
    await tick(5);
  }
}

/// 一个「侧边栏」:连 /hub,发 zoom_hello,收下所有消息
export async function sidebar(baseHttp, hello, { origin } = {}) {
  const url = `${baseHttp.replace(/^http/, 'ws')}/hub`;
  const ws = new WebSocket(url, origin ? { headers: { origin } } : {});
  const got = [];
  ws.on('message', (d) => got.push(JSON.parse(String(d))));
  await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); ws.once('unexpected-response', (_q, r) => rej(new Error(`http ${r.statusCode}`))); });
  const sb = {
    ws, got,
    send: (o) => ws.send(JSON.stringify(o)),
    of: (t) => got.filter((m) => m.t === t),
    last: (t) => { const xs = got.filter((m) => m.t === t); return xs[xs.length - 1]; },
    wait: (t, pred = () => true, ms = 5000) => until(() => got.filter((m) => m.t === t).find(pred), ms, `sidebar ${t}`),
    close: () => ws.close(),
  };
  if (hello) sb.send({ t: 'zoom_hello', ...hello });
  return sb;
}
