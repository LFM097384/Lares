#!/usr/bin/env node
// ember-desk · 命令行。
//   node ember-desk/cli.mjs status | join <link> [--k n] [--convener-name X] | leave | ask <text> | speak <text>
//                           | channels | start <id> | stop <id> | quit   [--json]
// join / ask / speak / start 会自动拉起守护进程;status 只报告「没在运行」(退出码 1)。
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { api, ensureDaemon, isRunning, NotRunningError, ApiError } from './client.mjs';
import { stateDir } from './paths.mjs';

const USAGE = `用法: node ember-desk/cli.mjs <命令> [--json]
  status                         状态
  join <链接> [--k n] [--convener-name 名字]   让炉灵进会
  leave                          离会
  ask <问题>                     提问(只在本机)
  speak <文字>                   朗读
  channels                       通道列表
  start <通道id> / stop <通道id>  启停通道
  quit                           退出守护进程`;

const STATE = { idle: '空闲', joining: '进会中', 'in-meeting': '会议中', leaving: '离会中' };
const SSTATE = { joining: '进会中', 'in-meeting': '会议中', ended: '已结束', failed: '失败' };

export function parseCli(argv) {
  const o = { json: false, args: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') o.json = true;
    else if (a === '--k') { o.k = Number(argv[++i]); if (!Number.isInteger(o.k)) throw new Error('--k 需要整数'); }
    else if (a === '--convener-name') { o.convenerName = argv[++i]; if (!o.convenerName) throw new Error('--convener-name 需要名字'); }
    else if (a === '-h' || a === '--help') o.help = true;
    else o.args.push(a);
  }
  o.cmd = o.args.shift();
  return o;
}

const sessLine = (s, label) => (s ? `${label}:${s.adapter} ${s.room ?? ''} · ${SSTATE[s.state] ?? s.state}${s.error ? ` · ${s.error}` : ''}` : null);
const chLine = (c) => `  ${c.running ? '●' : '○'} ${c.id.padEnd(14)} ${c.name}${c.configured ? '' : '(未配置)'}${c.enabled ? ' [自启]' : ''}  ${c.detail}`;

function friendly(cmd, r) {
  switch (cmd) {
    case 'status': return [`炉灵 v${r.version} · pid ${r.pid} · ${STATE[r.state] ?? r.state}`, sessLine(r.session, '当前会议'), !r.session ? sessLine(r.lastSession, '上次会议') : null, '通道:', ...r.channels.map(chLine)].filter(Boolean).join('\n');
    case 'join': return `正在进会:${r.adapter} ${r.room ?? ''}(会话 ${r.id})`;
    case 'leave': return r.session ? `已离会:${sessLine(r.session, '会议')}` : '当前没有会议';
    case 'ask': return `${r.answer}${r.llm ? '' : '\n(mock:未配置 LLM key)'}`;
    case 'speak': return r.ok ? `已朗读(${r.engine})` : `朗读失败(${r.engine}${r.error ? `:${r.error}` : ''})`;
    case 'channels': return r.map(chLine).join('\n');
    case 'start': case 'stop': return chLine(r);
    case 'quit': return '炉灵已退出';
    default: return JSON.stringify(r);
  }
}

export async function runCli(argv, { out = (s) => process.stdout.write(`${s}\n`), err = (s) => process.stderr.write(`${s}\n`), dir = stateDir() } = {}) {
  let o;
  try { o = parseCli(argv); } catch (e) { err(e.message); err(USAGE); return 2; }
  if (o.help || !o.cmd) { (o.help ? out : err)(USAGE); return o.help ? 0 : 2; }
  const text = o.args.join(' ').trim();
  const call = async () => {
    const opt = { dir };
    switch (o.cmd) {
      case 'status': return api('GET', '/status', undefined, opt);
      case 'join':
        if (!o.args[0]) throw new Error('缺少会议链接');
        await ensureDaemon({ dir });
        return api('POST', '/join', { link: o.args[0], ...(o.k !== undefined ? { k: o.k } : {}), ...(o.convenerName ? { convenerName: o.convenerName } : {}) }, opt);
      case 'leave': return api('POST', '/leave', {}, { ...opt, timeoutMs: 30_000 });
      case 'ask': if (!text) throw new Error('缺少问题'); await ensureDaemon({ dir }); return api('POST', '/ask', { text }, { ...opt, timeoutMs: 90_000 });
      case 'speak': if (!text) throw new Error('缺少朗读文字'); await ensureDaemon({ dir }); return api('POST', '/speak', { text }, { ...opt, timeoutMs: 150_000 });
      case 'channels': return api('GET', '/channels', undefined, opt);
      case 'start': case 'stop':
        if (!/^[a-z][a-z0-9-]{0,31}$/.test(o.args[0] ?? '')) throw new Error('缺少或不合法的通道 id');
        if (o.cmd === 'start') await ensureDaemon({ dir });
        return api('POST', `/channels/${o.args[0]}/${o.cmd}`, {}, opt);
      case 'quit': {
        if (!(await isRunning({ dir }))) throw new NotRunningError();
        const r = await api('POST', '/quit', {}, opt);
        for (let i = 0; i < 50 && (await isRunning({ dir })); i++) await new Promise((res) => setTimeout(res, 200));
        return r;
      }
      default: throw Object.assign(new Error(`未知命令:${o.cmd}`), { usage: true });
    }
  };
  try {
    const r = await call();
    out(o.json ? JSON.stringify(r) : friendly(o.cmd, r));
    return 0;
  } catch (e) {
    if (o.json) out(JSON.stringify({ error: e.code ?? e.body?.error ?? 'error', message: e.message, ...(e.status ? { status: e.status } : {}) }));
    else { err(e instanceof NotRunningError ? '炉灵没有在运行' : `错误:${e.message}`); if (e.usage) err(USAGE); }
    if (e.usage) return 2;
    if (e instanceof ApiError) return e.status === 409 ? 4 : 1;
    return 1;
  }
}

const isMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) runCli(process.argv.slice(2)).then((c) => { process.exitCode = c; });
