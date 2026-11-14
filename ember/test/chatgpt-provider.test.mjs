// chatgpt:<model> provider (ChatGPT Codex subscription) — mocked fetch, no network, temp auth file.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createChatGPTLLM, parseResponsesSSE, toResponses, resetSeconds, CODEX_API_URL, CODEX_TOKEN_URL } from '../bench/chatgpt.mjs';
import { parseSpec } from '../bench/providers.mjs';

const T0 = 1_800_000_000_000;
function authFile(expiresAt = T0 + 3600_000) {
  const dir = mkdtempSync(path.join(tmpdir(), 'ember-chatgpt-'));
  const f = path.join(dir, 'auth.json');
  writeFileSync(f, JSON.stringify({ claude: { keep: 1 }, codex: { default: 'acc1', accounts: { acc1: { accessToken: 'AT-SECRET', refreshToken: 'RT-SECRET', expiresAt, accountId: 'acct-1', idToken: 'x.y.z', planType: 'plus' } } } }));
  return f;
}
const sse = (text, usage = { input_tokens: 10, output_tokens: 5 }) => [
  { type: 'response.created', response: {} },
  { type: 'response.output_text.delta', delta: text.slice(0, 3) },
  { type: 'response.output_text.delta', delta: text.slice(3) },
  { type: 'response.completed', response: { usage, output: [] } },
].map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join('');
const ok = (text, headers = {}) => new Response(sse(text), { status: 200, headers: { 'content-type': 'text/event-stream', ...headers } });

test('chatgpt spec parses; family is not deepseek/qwen (judge independence holds)', () => {
  const p = parseSpec('chatgpt:gpt-5.6-luna');
  assert.equal(p.provider, 'chatgpt'); assert.equal(p.model, 'gpt-5.6-luna'); assert.equal(p.family, 'openai');
});

test('toResponses: system → instructions, json reminder only when input never says JSON', () => {
  const r = toResponses([{ role: 'system', content: 'S1' }, { role: 'user', content: 'U' }, { role: 'assistant', content: 'A' }], { json: true });
  assert.equal(r.instructions, 'S1');
  // backend requires "json" in the input messages: a trailing user item is appended, caller text untouched
  assert.deepEqual(r.input.map((i) => [i.role, i.content[0].type, i.content[0].text]), [['user', 'input_text', 'U'], ['assistant', 'output_text', 'A'], ['user', 'input_text', 'Respond with a single JSON object.']]);
  assert.equal(toResponses([{ role: 'system', content: 'S' }, { role: 'user', content: 'give json' }], { json: true }).input.length, 1);
  assert.equal(toResponses([{ role: 'user', content: 'u' }]).input.length, 1);
});

test('parseResponsesSSE: deltas, usage mapping, failure, truncation', () => {
  const r = parseResponsesSSE(sse('{"a":1}', { input_tokens: 7, output_tokens: 3, output_tokens_details: { reasoning_tokens: 1 } }));
  assert.equal(r.text, '{"a":1}'); assert.equal(r.finish, 'stop');
  assert.equal(r.usage.prompt_tokens, 7); assert.equal(r.usage.completion_tokens, 3); assert.equal(r.usage.reasoning_tokens, 1);
  assert.throws(() => parseResponsesSSE('data: {"type":"response.failed","response":{"error":{"code":"x","message":"boom"}}}\n\n'), /failed/);
  assert.throws(() => parseResponsesSSE('data: {"type":"response.output_text.delta","delta":"hi"}\n\n'), /ended before/);
  assert.throws(() => parseResponsesSSE('data: {"type":"error","error":{"type":"invalid_request_error","message":"need json"}}\n\n'), /invalid_request_error: need json/);
  const len = parseResponsesSSE('data: {"type":"response.output_text.delta","delta":"{"}\n\ndata: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}\n\n');
  assert.equal(len.finish, 'length');
});

test('request shape: endpoint, headers, body (json mode, no temperature), retry on 5xx', async () => {
  const seen = []; let n = 0;
  const fetchImpl = async (url, init) => { seen.push({ url, init, body: JSON.parse(init.body) }); return ++n === 1 ? new Response('x', { status: 502 }) : ok('{"x":1}', { 'x-codex-primary-used-percent': '3' }); };
  const llm = createChatGPTLLM({ model: 'gpt-5.6-luna', authFile: authFile(), fetchImpl, baseDelayMs: 1, now: () => T0 });
  const r = await llm.chat([{ role: 'system', content: 'Return JSON' }, { role: 'user', content: 'hi' }], { json: true, temperature: 0.7, maxTokens: 900 });
  assert.equal(r.text, '{"x":1}'); assert.equal(seen.length, 2);
  const { url, init, body } = seen[1];
  assert.equal(url, CODEX_API_URL);
  assert.equal(init.headers.authorization, 'Bearer AT-SECRET'); assert.equal(init.headers['chatgpt-account-id'], 'acct-1'); assert.equal(init.headers.originator, 'codex_cli_rs');
  assert.equal(body.model, 'gpt-5.6-luna'); assert.equal(body.store, false); assert.equal(body.stream, true); assert.equal(body.max_output_tokens, 900);
  assert.equal('temperature' in body, false); assert.deepEqual(body.text, { format: { type: 'json_object' } }); assert.deepEqual(body.reasoning, { effort: 'low' });
  assert.equal(llm.rateLimits['primary-used-percent'], 3);
});

test('errors never contain tokens', async () => {
  const llm = createChatGPTLLM({ model: 'm', authFile: authFile(), now: () => T0, fetchImpl: async () => new Response('bad AT-SECRET RT-SECRET', { status: 400 }) });
  await assert.rejects(llm.chat([{ role: 'user', content: 'hi' }]), (e) => /400/.test(e.message) && !/SECRET/.test(e.message));
});

test('429 short reset → waits and retries; long reset → clear usage-limit error', async () => {
  let n = 0;
  const short = createChatGPTLLM({ model: 'm', authFile: authFile(), now: () => T0, baseDelayMs: 1, fetchImpl: async () => (++n === 1 ? new Response(JSON.stringify({ error: { type: 'usage_limit_reached', resets_in_seconds: 0 } }), { status: 429 }) : ok('ok')) });
  assert.equal((await short.chat([{ role: 'user', content: 'x' }])).text, 'ok'); assert.equal(n, 2);
  const long = createChatGPTLLM({ model: 'm', authFile: authFile(), now: () => T0, fetchImpl: async () => new Response(JSON.stringify({ error: { type: 'usage_limit_reached', resets_in_seconds: 7200 } }), { status: 429 }) });
  await assert.rejects(long.chat([{ role: 'user', content: 'x' }]), /usage limit reached.*7200 s/);
  assert.equal(resetSeconds(JSON.stringify({ error: { resets_at: T0 / 1000 + 30 } }), T0), 30);
});

test('expired token → refresh grant, written back preserving other keys', async () => {
  const f = authFile(T0 - 1000); const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push(url);
    if (url === CODEX_TOKEN_URL) {
      const b = JSON.parse(init.body);
      assert.equal(b.grant_type, 'refresh_token'); assert.equal(b.refresh_token, 'RT-SECRET'); assert.equal(b.client_id, 'app_EMoamEEZ73f0CkXaXp7hrann');
      return new Response(JSON.stringify({ access_token: 'AT2', refresh_token: 'RT2', expires_in: 3600 }), { status: 200 });
    }
    assert.equal(init.headers.authorization, 'Bearer AT2');
    return ok('hi');
  };
  const llm = createChatGPTLLM({ model: 'm', authFile: f, fetchImpl, now: () => T0 });
  assert.equal((await llm.chat([{ role: 'user', content: 'x' }])).text, 'hi');
  assert.deepEqual(seen, [CODEX_TOKEN_URL, CODEX_API_URL]);
  const j = JSON.parse(readFileSync(f, 'utf8'));
  assert.deepEqual(j.claude, { keep: 1 });
  const a = j.codex.accounts.acc1;
  assert.equal(a.accessToken, 'AT2'); assert.equal(a.refreshToken, 'RT2'); assert.equal(a.expiresAt, T0 + 3600_000); assert.equal(a.planType, 'plus'); assert.equal(a.accountId, 'acct-1');
});

test('401 → one forced refresh; permanent refresh failure → re-login message', async () => {
  let api = 0;
  const llm = createChatGPTLLM({ model: 'm', authFile: authFile(), now: () => T0, fetchImpl: async (url) => {
    if (url === CODEX_TOKEN_URL) return new Response(JSON.stringify({ access_token: 'AT3', expires_in: 3600 }), { status: 200 });
    return ++api === 1 ? new Response('unauth', { status: 401 }) : ok('fine');
  } });
  assert.equal((await llm.chat([{ role: 'user', content: 'x' }])).text, 'fine');
  const dead = createChatGPTLLM({ model: 'm', authFile: authFile(T0 - 1), now: () => T0, fetchImpl: async () => new Response(JSON.stringify({ error: { code: 'refresh_token_reused' } }), { status: 401 }) });
  await assert.rejects(dead.chat([{ role: 'user', content: 'x' }]), (e) => /log in to ChatGPT again/.test(e.message) && !/SECRET/.test(e.message));
});

test('missing auth file → clear error', () => {
  assert.throws(() => createChatGPTLLM({ model: 'm', authFile: path.join(tmpdir(), 'nope-ember', 'auth.json') }), /cannot read auth file/);
});
