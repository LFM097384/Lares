import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { testDaemon, tmpDir, cleanEnv, DESK } from './helpers.mjs';
import { createMcpHandler } from '../mcp.mjs';

function mcpProc(t, dir) {
  const p = spawn(process.execPath, [path.join(DESK, 'mcp.mjs')], { env: cleanEnv({ EMBER_DESK_HOME: dir }), stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  t.after(() => { try { p.kill(); } catch { /* */ } });
  const lines = [];
  const waiters = [];
  readline.createInterface({ input: p.stdout }).on('line', (l) => { lines.push(l); waiters.splice(0).forEach((w) => w()); });
  const next = async () => { while (!lines.length) await new Promise((r) => waiters.push(r)); return lines.shift(); };
  const rpc = async (msg) => { p.stdin.write(`${typeof msg === 'string' ? msg : JSON.stringify(msg)}\n`); return JSON.parse(await next()); };
  return { p, rpc, lines, send: (m) => p.stdin.write(`${JSON.stringify(m)}\n`) };
}

test('MCP stdio: handshake, tools/list, tools/call against a live daemon with fake plugin', async (t) => {
  const dir = tmpDir(t);
  const d = await testDaemon(t, { dir });
  const m = mcpProc(t, dir);
  const init = await m.rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 't', version: '1' } } });
  assert.equal(init.id, 1);
  assert.equal(init.result.protocolVersion, '2025-03-26');
  assert.deepEqual(init.result.capabilities, { tools: {} });
  assert.equal(init.result.serverInfo.name, 'ember-desk');
  m.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  assert.deepEqual(await m.rpc({ jsonrpc: '2.0', id: 2, method: 'ping' }), { jsonrpc: '2.0', id: 2, result: {} });
  const list = await m.rpc({ jsonrpc: '2.0', id: 3, method: 'tools/list' });
  assert.deepEqual(list.result.tools.map((x) => x.name), ['ember_status', 'ember_join_meeting', 'ember_leave_meeting', 'ember_ask', 'ember_speak', 'ember_channels']);
  const st = await m.rpc({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'ember_status', arguments: {} } });
  assert.equal(st.result.isError, undefined);
  assert.equal(JSON.parse(st.result.content[0].text).pid, process.pid);
  const j = await m.rpc({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'ember_join_meeting', arguments: { link: 'https://localhost:8443/mcp1', k: 1 } } });
  assert.equal(JSON.parse(j.result.content[0].text).room, 'mcp1');
  const bad = await m.rpc({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'ember_join_meeting', arguments: { link: 'http://x/y' } } });
  assert.equal(bad.result.isError, true);
  assert.match(bad.result.content[0].text, /错误/);
  const lv = await m.rpc({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'ember_leave_meeting', arguments: {} } });
  assert.equal(JSON.parse(lv.result.content[0].text).ok, true);
  const ask = await m.rpc({ jsonrpc: '2.0', id: 8, method: 'tools/call', params: { name: 'ember_ask', arguments: { text: '你好' } } });
  assert.equal(JSON.parse(ask.result.content[0].text).llm, false);
  const ch = await m.rpc({ jsonrpc: '2.0', id: 9, method: 'tools/call', params: { name: 'ember_channels', arguments: {} } });
  assert.equal(JSON.parse(ch.result.content[0].text).length, 9);
  assert.equal((await m.rpc({ jsonrpc: '2.0', id: 10, method: 'nope/x' })).error.code, -32601);
  assert.equal((await m.rpc('{not json')).error.code, -32700);
  assert.equal((await m.rpc({ jsonrpc: '2.0', id: 11, method: 'tools/call', params: { name: 'no_such_tool' } })).error.code, -32602);
  // stdout 只有 JSON-RPC
  for (const l of m.lines) assert.equal(JSON.parse(l).jsonrpc, '2.0');
  m.p.stdin.end();
  await new Promise((r) => m.p.once('exit', r));
  assert.equal(d.sessions.state, 'idle');
});

test('MCP handler auto-starts the daemon once on first tool call', async () => {
  let ensured = 0;
  const calls = [];
  const h = createMcpHandler({ dir: 'X', ensure: async () => { ensured++; }, call: async (m, p, b) => { calls.push([m, p, b]); return { ok: true }; } });
  assert.equal(await h({ jsonrpc: '2.0', method: 'notifications/initialized' }), null);
  assert.equal(ensured, 0);
  await h({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'ember_speak', arguments: { text: 'hi' } } });
  await h({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'ember_join_meeting', arguments: { link: 'https://a/b', convener_name: '李' } } });
  assert.equal(ensured, 1);
  assert.deepEqual(calls, [['POST', '/speak', { text: 'hi' }], ['POST', '/join', { link: 'https://a/b', convenerName: '李' }]]);
  const e = await h({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'ember_ask', arguments: { text: '' } } });
  assert.equal(e.result.isError, true);
  assert.equal((await h({ jsonrpc: '2.0', id: 4, method: 'initialize', params: {} })).result.protocolVersion, '2025-06-18');
  assert.equal((await h({ id: 5, method: 'x' })).error.code, -32600);
});
