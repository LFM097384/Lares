#!/usr/bin/env node
// ember-desk · MCP stdio 服务器(手写,JSON-RPC 2.0,一行一条)。stdout 只有 JSON-RPC;日志走 stderr。
// 第一次 tools/call 时自动拉起守护进程(ensureDaemon)。
import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';
import { api, ensureDaemon, ApiError } from './client.mjs';
import { stateDir, VERSION } from './paths.mjs';

export const DEFAULT_PROTOCOL = '2025-06-18';

export const TOOLS = [
  { name: 'ember_status', description: '炉灵桌面端状态:空闲 / 会议中、当前与上次会话、各通道', inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
  {
    name: 'ember_join_meeting', description: '让炉灵加入一个会议(Jitsi 链接可直接加入;Zoom / Lares 链接会返回说明)',
    inputSchema: { type: 'object', properties: { link: { type: 'string', description: 'https 会议链接' }, k: { type: 'integer', minimum: 1, maximum: 20, description: '放行门槛 k-of-n(可选)' }, convener_name: { type: 'string', description: '召集人显示名(可选)' } }, required: ['link'], additionalProperties: false },
  },
  { name: 'ember_leave_meeting', description: '让炉灵离开当前会议', inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
  { name: 'ember_ask', description: '向炉灵提问(只在本机;不会进入任何会议)', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'], additionalProperties: false } },
  { name: 'ember_speak', description: '让炉灵在本机朗读一段文字', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'], additionalProperties: false } },
  { name: 'ember_channels', description: '列出炉灵的输入 / 输出 / 会议通道', inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
];

const text = (t, isError = false) => ({ content: [{ type: 'text', text: typeof t === 'string' ? t : JSON.stringify(t, null, 2) }], ...(isError ? { isError: true } : {}) });

export function createMcpHandler({ dir = stateDir(), ensure = (d) => ensureDaemon({ dir: d }), call = (m, p, b, o) => api(m, p, b, o) } = {}) {
  let started = false;
  const opt = (t) => ({ dir, ...(t ? { timeoutMs: t } : {}) });
  const str = (v, name) => { if (typeof v !== 'string' || !v.trim()) throw Object.assign(new Error(`参数 ${name} 必须是非空字符串`), { invalid: true }); return v; };

  async function tool(name, a = {}) {
    if (!TOOLS.some((t) => t.name === name)) throw Object.assign(new Error(`unknown tool ${name}`), { rpc: -32602 });
    if (a === null || typeof a !== 'object' || Array.isArray(a)) throw Object.assign(new Error('arguments must be an object'), { rpc: -32602 });
    if (!started) { await ensure(dir); started = true; }
    switch (name) {
      case 'ember_status': return call('GET', '/status', undefined, opt());
      case 'ember_join_meeting': {
        const body = { link: str(a.link, 'link') };
        if (a.k !== undefined) body.k = a.k;
        if (a.convener_name !== undefined) body.convenerName = str(a.convener_name, 'convener_name');
        return call('POST', '/join', body, opt());
      }
      case 'ember_leave_meeting': return call('POST', '/leave', {}, opt(30_000));
      case 'ember_ask': return call('POST', '/ask', { text: str(a.text, 'text') }, opt(90_000));
      case 'ember_speak': return call('POST', '/speak', { text: str(a.text, 'text') }, opt(150_000));
      case 'ember_channels': return call('GET', '/channels', undefined, opt());
      default: throw new Error('unreachable');
    }
  }

  /// 处理一条消息,返回回复对象或 null(通知)
  return async function handle(msg) {
    if (!msg || typeof msg !== 'object' || Array.isArray(msg) || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') {
      return { jsonrpc: '2.0', id: msg?.id ?? null, error: { code: -32600, message: 'Invalid Request' } };
    }
    const isNote = !('id' in msg);
    const reply = (result) => (isNote ? null : { jsonrpc: '2.0', id: msg.id, result });
    const fail = (code, message) => (isNote ? null : { jsonrpc: '2.0', id: msg.id, error: { code, message } });
    switch (msg.method) {
      case 'initialize': {
        const pv = typeof msg.params?.protocolVersion === 'string' ? msg.params.protocolVersion : DEFAULT_PROTOCOL;
        return reply({ protocolVersion: pv, capabilities: { tools: {} }, serverInfo: { name: 'ember-desk', version: VERSION }, instructions: '炉灵桌面端:让炉灵进出会议、本机提问与朗读。' });
      }
      case 'notifications/initialized': case 'notifications/cancelled': return null;
      case 'ping': return reply({});
      case 'tools/list': return reply({ tools: TOOLS });
      case 'tools/call': {
        try {
          const r = await tool(msg.params?.name, msg.params?.arguments ?? {});
          return reply(text(r));
        } catch (e) {
          if (e.rpc) return fail(e.rpc, e.message);
          const detail = e instanceof ApiError ? (e.body?.message ?? e.message) : e.message;
          return reply(text(`错误:${detail}`, true));
        }
      }
      default:
        if (msg.method.startsWith('notifications/')) return null;
        return fail(-32601, `Method not found: ${msg.method}`);
    }
  };
}

export function runMcp({ input = process.stdin, output = process.stdout, handler = createMcpHandler() } = {}) {
  const write = (o) => output.write(`${JSON.stringify(o)}\n`);
  const rl = readline.createInterface({ input });
  const pending = new Set();
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); return; }
    const p = (async () => {
      if (Array.isArray(msg)) {
        if (!msg.length) { write({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid Request' } }); return; }
        const rs = (await Promise.all(msg.map((m) => handler(m)))).filter(Boolean);
        if (rs.length) write(rs);
        return;
      }
      const r = await handler(msg);
      if (r) write(r);
    })().catch((e) => process.stderr.write(`[ember-desk mcp] ${e.message}\n`)).finally(() => pending.delete(p));
    pending.add(p);
  });
  return new Promise((resolve) => rl.on('close', async () => { await Promise.all(pending); resolve(); }));
}

const isMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) runMcp().then(() => { process.exitCode = 0; });
