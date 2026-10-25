// ember-desk · 会议链接解析与路由。只收 https:;拒绝 URL 内凭据、控制字符、超长。
//   Jitsi:host[:port] 在 config.jitsiHosts 里,或异步探测(GET /config.js 或 /libs/lib-jitsi-meet.min.js 返回 200)
//   Zoom:*.zoom.us/j/<digits> 或 /wc/<digits>(含 /wc/join/<digits>)
//   Lares:host 含 lares,或路径以 /circle/ 开头 → 由 Lares 服务器按圈拉起,不由桌面端启动
import https from 'node:https';

export const MAX_LINK = 2048;
export const ROOM_RE = /^[A-Za-z0-9_.-]{1,64}$/;

export class LinkError extends Error {
  constructor(code, message) { super(message); this.name = 'LinkError'; this.code = code; }
}

const LOOPBACK = new Set(['localhost', '127.0.0.1', '[::1]']);

/// 同步的形状检查:返回 URL 对象或抛 LinkError
export function checkUrl(link) {
  if (typeof link !== 'string' || !link.trim()) throw new LinkError('empty', '链接为空');
  const s = link.trim();
  if (s.length > MAX_LINK) throw new LinkError('too_long', `链接太长(上限 ${MAX_LINK} 字符)`);
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f-\u009f]/.test(s)) throw new LinkError('control_chars', '链接含控制字符');
  if (/%00/i.test(s)) throw new LinkError('control_chars', '链接含空字节');
  let u;
  try { u = new URL(s); } catch { throw new LinkError('not_url', '不是有效的网址'); }
  if (u.protocol !== 'https:') throw new LinkError('not_https', `只支持 https 链接(收到 ${u.protocol.replace(/:$/, '')})`);
  if (u.username || u.password) throw new LinkError('credentials', '链接里不能带用户名或密码');
  if (!u.hostname) throw new LinkError('no_host', '链接缺少主机名');
  return u;
}

export const hostKey = (u) => (u.port ? `${u.hostname}:${u.port}` : u.hostname).toLowerCase();

function zoomOf(u) {
  const h = u.hostname.toLowerCase();
  if (!(h === 'zoom.us' || h.endsWith('.zoom.us') || h === 'zoom.com' || h.endsWith('.zoom.com'))) return null;
  const m = u.pathname.match(/^\/(?:j|wc(?:\/join)?|s)\/(\d{9,12})(?:\/|$)/) ?? u.pathname.match(/^\/wc\/(\d{9,12})\/(?:join|start)$/);
  if (!m) throw new LinkError('zoom_bad_path', 'Zoom 链接格式不认识(应为 https://xxx.zoom.us/j/<会议号>)');
  return { adapter: 'zoom', meetingId: m[1], host: h, url: `https://${h}`, passcodePresent: u.searchParams.has('pwd') };
}

function laresOf(u) {
  const h = u.hostname.toLowerCase();
  if (h.includes('lares') || /^\/circle\//.test(u.pathname)) {
    const m = u.pathname.match(/^\/circle\/([A-Za-z0-9_-]{1,64})/);
    return { adapter: 'lares', host: h, url: `https://${hostKey(u)}`, circleId: m?.[1] ?? null };
  }
  return null;
}

function roomOf(u) {
  const seg = u.pathname.split('/').filter(Boolean)[0];
  if (!seg) throw new LinkError('no_room', 'Jitsi 链接缺少房间名(https://主机/房间名)');
  let room;
  try { room = decodeURIComponent(seg); } catch { throw new LinkError('bad_room', '房间名编码不合法'); }
  if (!ROOM_RE.test(room)) throw new LinkError('bad_room', '房间名只能包含字母、数字、_ . -,最长 64 个字符');
  return room.toLowerCase();
}

/**
 * 默认探测:GET https://host[:port]/config.js(再试 /libs/lib-jitsi-meet.min.js)返回 200 即视为 Jitsi。
 * 只有 localhost / 127.0.0.1 接受自签证书。4 s 超时。
 */
export async function defaultProbe(u, { timeoutMs = 4000 } = {}) {
  const insecure = LOOPBACK.has(u.hostname.toLowerCase());
  const one = (p) => new Promise((resolve) => {
    const req = https.request({ hostname: u.hostname.replace(/^\[|\]$/g, ''), port: u.port || 443, path: p, method: 'GET', rejectUnauthorized: !insecure, timeout: timeoutMs, headers: { 'user-agent': 'ember-desk/0.1' } }, (res) => {
      res.resume();
      resolve(res.statusCode === 200);
    });
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
    req.end();
  });
  if (await one('/config.js')) return true;
  return one('/libs/lib-jitsi-meet.min.js');
}

/**
 * parseLink(link, {jitsiHosts, probe}) → {adapter:'jitsi', url, room, link} | {adapter:'zoom', meetingId, ...} | {adapter:'lares', ...}
 * 不认识 / 不合法 → 抛 LinkError(中文 message)。
 */
export async function parseLink(link, { jitsiHosts = [], probe = defaultProbe } = {}) {
  const u = checkUrl(link);
  const clean = u.href;
  const z = zoomOf(u);
  if (z) return { ...z, link: clean };
  const l = laresOf(u);
  if (l) return { ...l, link: clean };
  const hk = hostKey(u);
  const configured = jitsiHosts.map((h) => String(h).toLowerCase()).includes(hk);
  const room = roomOf(u);
  if (!configured) {
    let ok = false;
    try { ok = probe ? await probe(u) : false; } catch { ok = false; }
    if (!ok) throw new LinkError('unknown_host', `不认识的会议主机 ${hk}:不在 jitsiHosts 配置里,也探测不到 Jitsi(可在 config.json 的 jitsiHosts 里加上它)`);
  }
  return { adapter: 'jitsi', url: `https://${hk}`, room, link: clean, via: configured ? 'config' : 'probe' };
}
