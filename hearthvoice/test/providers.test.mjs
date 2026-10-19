// 灶语本体 provider:DashScope 的主机 / 日志 / WebSocket 可注入(不联网,用假 WebSocket);extra body 解析。
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { DashscopeAsr, DashscopeTts, DASHSCOPE_DEFAULT_HOST, resolveExtraBody } from '../index.mjs';

class FakeWs extends EventEmitter {
  static last = [];
  constructor(url, opts) { super(); this.url = url; this.opts = opts; this.sent = []; this.readyState = 0; FakeWs.last.push(this); }
  send(s) { this.sent.push(JSON.parse(s)); }
  close() { this.readyState = 3; }
  terminate() { this.readyState = 3; }
}

test('DashscopeAsr:注入的 WebSocket / host / log 生效,密钥只在请求头', async () => {
  FakeWs.last = [];
  const logs = [];
  const asr = new DashscopeAsr({ apiKey: 'k-not-real', host: 'ds.example', log: (m) => logs.push(m), WebSocket: FakeWs });
  const p = asr.warmup(1000);
  const ws = FakeWs.last[0];
  assert.equal(ws.url, 'wss://ds.example/api-ws/v1/realtime?model=qwen3-asr-flash-realtime');
  assert.equal(ws.opts.headers.Authorization, 'Bearer k-not-real');
  assert.ok(!ws.url.includes('k-not-real'));
  ws.emit('open');
  assert.equal(await p, true);
  assert.match(logs[0], /^asr warm-up ok/);
});

test('DashscopeAsr:hints → input_audio_transcription.corpus.text(唤醒词偏置);没 hints 不带', () => {
  FakeWs.last = [];
  const asr = new DashscopeAsr({ apiKey: 'k', WebSocket: FakeWs, log: () => {} });
  asr.open({ identity: 'u1', hints: ['灶语', ' 灶语 ', '', '小灶'] });
  asr.open({ identity: 'u2' });
  const [a, b] = FakeWs.last;
  a.emit('message', Buffer.from(JSON.stringify({ type: 'session.created' })));
  b.emit('message', Buffer.from(JSON.stringify({ type: 'session.created' })));
  assert.deepEqual(a.sent[0].session.input_audio_transcription, { corpus: { text: '灶语，小灶' } });
  assert.deepEqual(b.sent[0].session.input_audio_transcription, {});
});

test('DashscopeTts:默认主机;session.updated 后 open() 返回会话', async () => {
  FakeWs.last = [];
  const tts = new DashscopeTts({ apiKey: 'k', WebSocket: FakeWs, log: () => {} });
  const p = tts.open({ voice: 'Cherry' });
  const ws = FakeWs.last[0];
  assert.ok(ws.url.startsWith(`wss://${DASHSCOPE_DEFAULT_HOST}/`));
  ws.readyState = 1;
  ws.emit('message', Buffer.from(JSON.stringify({ type: 'session.created' })));
  assert.equal(ws.sent[0].type, 'session.update');
  assert.equal(ws.sent[0].session.voice, 'Cherry');
  ws.emit('message', Buffer.from(JSON.stringify({ type: 'session.updated' })));
  const s = await p;
  assert.equal(s.alive, true);
  s.close();
  assert.equal(s.alive, false);
});

test('缺密钥直接报错', () => {
  assert.throws(() => new DashscopeAsr({ WebSocket: FakeWs }), /dashscope_api_key_missing/);
  assert.throws(() => new DashscopeTts({ WebSocket: FakeWs }), /dashscope_api_key_missing/);
});

test('resolveExtraBody:DeepSeek 默认关思考;错误信息不含平台变量名', () => {
  assert.deepEqual(resolveExtraBody(undefined, 'https://api.deepseek.com'), { thinking: { type: 'disabled' } });
  assert.throws(() => resolveExtraBody('nope', 'https://x'), /^Error: extra_body: invalid JSON$/);
  assert.throws(() => resolveExtraBody('[1]', 'https://x'), /extra_body: must be a JSON object/);
});
