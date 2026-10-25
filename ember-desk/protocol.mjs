#!/usr/bin/env node
// ember-desk · ember:// 协议处理器。`node protocol.mjs "<url>"`(注册表命令行见 registryCommandLine)。
//   ember://join?link=<https 会议链接>   ember://leave   ember://status   ember://open(打开状态页)
// parseEmberUrl 是纯函数,严格白名单:未知动作 / 未知参数 / 重复参数 / 引号、反引号、换行、控制字符、%00 一律拒绝。
// 结果用 Windows 通知显示(经 output-toast 的 WinRT 脚本;文字走 env base64)。
import path from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { checkUrl, MAX_LINK, LinkError } from './links.mjs';

export class ProtocolError extends Error {
  constructor(code, message) { super(message); this.name = 'ProtocolError'; this.code = code; }
}

const ACTIONS = { join: ['link'], leave: [], status: [], open: [] };
// 解码后仍不许出现的字符:引号、反引号、尖括号、换行 / 控制字符、shell / cmd 元字符里危险的那些
// eslint-disable-next-line no-control-regex
const BAD = /["'`<>\\^|\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

export function parseEmberUrl(raw) {
  if (typeof raw !== 'string') throw new ProtocolError('bad_url', 'URL 必须是字符串');
  if (raw.length > MAX_LINK + 64) throw new ProtocolError('too_long', 'URL 太长');
  if (BAD.test(raw) || /%00/i.test(raw) || /\s/.test(raw)) throw new ProtocolError('bad_chars', 'URL 含不允许的字符');
  let u;
  try { u = new URL(raw); } catch { throw new ProtocolError('bad_url', '不是合法的 URL'); }
  if (u.protocol !== 'ember:') throw new ProtocolError('bad_scheme', '只处理 ember:// 链接');
  if (u.username || u.password || u.port || u.hash) throw new ProtocolError('bad_url', 'ember:// 链接不能带用户名、端口或 #');
  // ember://join?… → host='join', pathname='';也接受 ember:join?…(pathname='join')
  const action = (u.host || u.pathname.replace(/^\/+/, '')).replace(/\/+$/, '').toLowerCase();
  if (u.host && u.pathname && u.pathname !== '/') throw new ProtocolError('bad_url', 'ember:// 链接不能带路径');
  if (!Object.hasOwn(ACTIONS, action)) throw new ProtocolError('bad_action', `未知动作:${action.slice(0, 32)}`);
  const allowed = ACTIONS[action];
  const params = {};
  for (const [k, v] of u.searchParams) {
    if (!allowed.includes(k)) throw new ProtocolError('bad_param', `不认识的参数:${k.slice(0, 32)}`);
    if (Object.hasOwn(params, k)) throw new ProtocolError('bad_param', `参数重复:${k}`);
    if (BAD.test(v) || /\s/.test(v) || /%00/i.test(v)) throw new ProtocolError('bad_chars', `参数 ${k} 含不允许的字符`);
    params[k] = v;
  }
  if (action === 'join') {
    if (!params.link) throw new ProtocolError('missing_link', '缺少 link 参数');
    if (params.link.length > MAX_LINK) throw new ProtocolError('too_long', '会议链接太长');
    let lu;
    try { lu = checkUrl(params.link); } catch (e) { throw new ProtocolError(e instanceof LinkError ? e.code : 'bad_link', `会议链接不合法:${e.message}`); }
    return { action, link: lu.href };
  }
  return { action };
}

/// 注册表命令行:"<node>" "<script>" "%1"。路径里有 " 就拒绝(无法安全转义)。
export function registryCommandLine(nodePath, scriptPath) {
  for (const [n, p] of [['nodePath', nodePath], ['scriptPath', scriptPath]]) {
    if (typeof p !== 'string' || !p) throw new ProtocolError('bad_path', `${n} 为空`);
    // eslint-disable-next-line no-control-regex
    if (/["\u0000-\u001f%]/.test(p)) throw new ProtocolError('bad_path', `${n} 含引号、% 或控制字符`);
    if (!path.isAbsolute(p)) throw new ProtocolError('bad_path', `${n} 必须是绝对路径`);
  }
  return `"${nodePath}" "${scriptPath}" "%1"`;
}

async function toast(title, text) {
  const { WINRT_SCRIPT } = await import('./channels/output-toast.mjs');
  const { runPs, WINPS } = await import('./ps.mjs');
  if (process.platform !== 'win32') { process.stderr.write(`${title}: ${text}\n`); return; }
  await runPs(WINPS, WINRT_SCRIPT, { payload: { title, text: String(text).slice(0, 400) }, timeoutMs: 15_000, spawnImpl: spawn });
}

export async function handleEmberUrl(raw, { notify = toast, client } = {}) {
  let p;
  try { p = parseEmberUrl(raw); } catch (e) { await notify('炉灵:链接被拒绝', e.message); return 2; }
  const c = client ?? await import('./client.mjs');
  try {
    if (p.action === 'join') {
      await c.ensureDaemon();
      const r = await c.api('POST', '/join', { link: p.link });
      await notify('炉灵正在进会', `${r.adapter} ${r.room ?? ''}`);
    } else if (p.action === 'leave') {
      const r = await c.api('POST', '/leave', {});
      await notify('炉灵', r.session ? '已离会' : '当前没有会议');
    } else if (p.action === 'status') {
      const s = await c.ensureDaemon();
      await notify('炉灵', s.session ? `会议中:${s.session.room ?? s.session.adapter}` : '空闲');
    } else if (p.action === 'open') {
      await c.ensureDaemon();
      const st = c.readState(); const tok = c.readToken();
      // 只用 explorer 打开本机 URL;参数是固定格式,不经 shell
      spawn('explorer.exe', [`http://127.0.0.1:${st.port}/ui#${tok}`], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    }
    return 0;
  } catch (e) {
    await notify('炉灵:操作失败', e.body?.message ?? e.message);
    return 1;
  }
}

const isMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  if (process.argv.length !== 3) { process.stderr.write('usage: node protocol.mjs "ember://…"\n'); process.exitCode = 2; }
  else handleEmberUrl(process.argv[2]).then((c) => { process.exitCode = c; });
}
