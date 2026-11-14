// EmberBench · ChatGPT (Codex) subscription provider: spec "chatgpt:<model>", e.g. chatgpt:gpt-5.6-luna.
// Mirrors the DSH subscriptions plugin (dsh-plugin-subscriptions 0.9.2, lib/providers/codex.js):
//   POST https://chatgpt.com/backend-api/codex/responses   (OpenAI Responses API, SSE stream, store:false)
//   headers: authorization Bearer <access>, chatgpt-account-id, originator: codex_cli_rs, accept: text/event-stream
// Credentials are read at runtime from CHATGPT_AUTH_FILE (default ~/.dsh/plugins/subscriptions/auth.json, key "codex").
// Tokens are never logged, never put in error text, never written anywhere except back into that same file.
// Refresh: when the access token has < 5 min left (or the backend answers 401) we re-read the file first (DSH may have
// refreshed it already), then POST https://auth.openai.com/oauth/token {grant_type:refresh_token} like the plugin, and
// write accessToken/refreshToken/expiresAt/idToken back into codex.accounts[<id>] atomically (tmp + rename), keeping
// every other key of the file. A permanent refresh failure throws "re-login in DSH" — we never delete anything.
// Option mapping from the ember llm contract chat(messages, { json, temperature, maxTokens }):
//   system messages → `instructions`; user/assistant → `input` items
//   json → text.format {type:'json_object'} (+ a one-line JSON reminder if the prompt never says "JSON")
//   maxTokens → max_output_tokens; temperature / seed → IGNORED (the Codex backend rejects `temperature`: HTTP 400)
//   reasoning effort: env CHATGPT_REASONING_EFFORT (default "low"; gate calls are short structured edits)
// 429 / usage_limit_reached: retried with backoff when the window resets within CHATGPT_MAX_WAIT_S (default 90 s);
// otherwise a clear "usage limit reached, resets in …" error. The last x-codex-* window headers are kept in llm.rateLimits.
import { readFileSync, writeFileSync, renameSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

export const CODEX_API_URL = 'https://chatgpt.com/backend-api/codex/responses';
export const CODEX_TOKEN_URL = 'https://auth.openai.com/oauth/token';
export const CODEX_CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann';
const PREEMPT_MS = 5 * 60_000;
const PERMANENT = new Set(['refresh_token_expired', 'refresh_token_reused', 'refresh_token_invalidated', 'invalid_grant']);

export const defaultAuthFile = () => process.env.CHATGPT_AUTH_FILE || path.join(homedir(), '.dsh', 'plugins', 'subscriptions', 'auth.json');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function decodeJwt(t) {
  try { return JSON.parse(Buffer.from(String(t).split('.')[1], 'base64url').toString('utf8')); } catch { return null; }
}

/** Read the default (or named) codex account from the auth file. */
export function readCodexSession(file, account) {
  let j;
  try { j = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { throw new Error(`chatgpt: cannot read auth file ${file} (${e.code || 'invalid JSON'}); log in to ChatGPT in DSH Subscriptions first`); }
  const c = j?.codex;
  const id = account || c?.default;
  const s = c?.accounts?.[id];
  if (!s?.accessToken || !s?.refreshToken || !s?.accountId) throw new Error(`chatgpt: no usable codex account in ${file}; log in to ChatGPT in DSH Subscriptions first`);
  return { id, ...s };
}

function writeBack(file, id, fresh) {
  const j = JSON.parse(readFileSync(file, 'utf8')); // re-read: keep anything written since
  const cur = j.codex?.accounts?.[id];
  if (!cur) throw new Error('chatgpt: account vanished from auth file during refresh');
  j.codex.accounts[id] = { ...cur, ...fresh };
  const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`;
  try { writeFileSync(tmp, JSON.stringify(j, null, 2), { mode: 0o600 }); renameSync(tmp, file); } catch (e) { rmSync(tmp, { force: true }); throw new Error(`chatgpt: could not write refreshed tokens (${e.code || e.message})`); }
}

/** Seconds until the rejecting window resets, from the body (plugin: body only, never the rollover headers). */
export function resetSeconds(bodyText, now = Date.now()) {
  let b; try { b = JSON.parse(bodyText); } catch { return null; }
  const e = b?.error ?? b?.detail ?? b;
  for (const k of ['resets_in_seconds', 'reset_after_seconds']) if (Number.isFinite(e?.[k])) return e[k];
  for (const k of ['resets_at', 'reset_at']) if (Number.isFinite(e?.[k])) return Math.max(0, e[k] - now / 1000);
  return null;
}

/** Messages (ember contract) → Responses { instructions, input }. */
export function toResponses(messages, { json = false } = {}) {
  const sys = [], input = [];
  for (const m of messages || []) {
    const text = typeof m.content === 'string' ? m.content : JSON.stringify(m.content);
    if (m.role === 'system') { sys.push(text); continue; }
    const role = m.role === 'assistant' ? 'assistant' : 'user';
    input.push({ type: 'message', role, content: [{ type: role === 'assistant' ? 'output_text' : 'input_text', text }] });
  }
  const instructions = sys.join('\n\n') || 'You are a helpful assistant.';
  if (!input.length) input.push({ type: 'message', role: 'user', content: [{ type: 'input_text', text: '' }] });
  // json_object mode: the backend requires the word "json" in the INPUT messages (instructions do not count).
  // Add it as a separate trailing user item so the caller's own text is never altered.
  if (json && !input.some((i) => /json/i.test(i.content[0].text))) input.push({ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Respond with a single JSON object.' }] });
  return { instructions, input };
}

/** Parse a Responses SSE body (string) → { text, usage, finish }. Throws on response.failed / error events. */
export function parseResponsesSSE(raw) {
  let text = '', done = null, data = [];
  const events = [];
  for (const line0 of String(raw).split('\n')) {
    const line = line0.endsWith('\r') ? line0.slice(0, -1) : line0;
    if (!line) { if (data.length) events.push(data.join('\n')); data = []; continue; }
    if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''));
  }
  if (data.length) events.push(data.join('\n'));
  for (const d of events) {
    if (d === '[DONE]') continue;
    let e; try { e = JSON.parse(d); } catch { continue; }
    if (e.type === 'response.output_text.delta') text += e.delta ?? '';
    else if (e.type === 'response.completed') done = { r: e.response, finish: 'stop' };
    else if (e.type === 'response.incomplete') {
      const why = e.response?.incomplete_details?.reason;
      if (why === 'max_output_tokens') done = { r: e.response, finish: 'length' };
      else throw new Error(`chatgpt: response incomplete (${why || 'unknown'})`);
    } else if (e.type === 'response.failed') throw new Error(`chatgpt: response failed (${e.response?.error?.code || ''} ${String(e.response?.error?.message || '').slice(0, 200)})`);
    else if (e.type === 'error') { const x = e.error || e; throw new Error(`chatgpt: stream error (${x.type || x.code || ''}: ${String(x.message || '').slice(0, 200)})`); }
  }
  if (!done) throw new Error('chatgpt: SSE stream ended before response.completed');
  if (!text) text = (done.r?.output || []).filter((o) => o.type === 'message').flatMap((o) => o.content || []).filter((c) => c.type === 'output_text').map((c) => c.text).join('');
  const u = done.r?.usage || {};
  return { text, finish: done.finish, usage: { prompt_tokens: u.input_tokens || 0, completion_tokens: u.output_tokens || 0, reasoning_tokens: u.output_tokens_details?.reasoning_tokens || 0, cached_tokens: u.input_tokens_details?.cached_tokens || 0 } };
}

export function createChatGPTLLM({ model, authFile = defaultAuthFile(), account, fetchImpl, effort = process.env.CHATGPT_REASONING_EFFORT || 'low',
  retries = 6, timeoutMs = 300000, maxWaitS = Number(process.env.CHATGPT_MAX_WAIT_S || 90), baseDelayMs = 1500, now = () => Date.now() } = {}) {
  if (!model) throw new Error('createChatGPTLLM: model is required');
  const doFetch = fetchImpl || globalThis.fetch;
  let session = readCodexSession(authFile, account);
  let refreshing = null;
  const scrub = (s) => { let t = String(s ?? ''); for (const k of [session.accessToken, session.refreshToken, session.idToken]) if (k) t = t.split(k).join('***'); return t; };
  const state = { rateLimits: null, refreshes: 0 };

  async function refresh(force) {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      const onDisk = readCodexSession(authFile, session.id); // DSH may already have rotated it
      if (onDisk.accessToken !== session.accessToken && onDisk.expiresAt - now() > PREEMPT_MS) { session = onDisk; return; }
      if (!force && onDisk.expiresAt - now() > PREEMPT_MS) { session = onDisk; return; }
      let res;
      try {
        res = await doFetch(CODEX_TOKEN_URL, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ client_id: CODEX_CLIENT_ID, grant_type: 'refresh_token', refresh_token: onDisk.refreshToken }), signal: AbortSignal.timeout(60000) });
      } catch (e) { throw new Error(scrub(`chatgpt: token refresh network error ${e?.name || ''} ${e?.message || ''}`)); }
      const body = await res.text().catch(() => '');
      if (!res.ok) {
        let code; try { const b = JSON.parse(body); code = b?.error?.code || b?.error || b?.code; } catch {}
        if (PERMANENT.has(code)) throw new Error(`chatgpt: refresh token rejected (${code}); log in to ChatGPT again in DSH Subscriptions`);
        throw new Error(`chatgpt: token refresh HTTP ${res.status} (${typeof code === 'string' ? code : 'no code'})`);
      }
      const t = JSON.parse(body);
      if (!t.access_token) throw new Error('chatgpt: token endpoint returned no access token');
      const exp = t.expires_in > 0 ? now() + t.expires_in * 1000 : (decodeJwt(t.access_token)?.exp || 0) * 1000;
      if (!exp) throw new Error('chatgpt: token endpoint returned no usable expiry');
      const fresh = { accessToken: t.access_token, refreshToken: t.refresh_token || onDisk.refreshToken, expiresAt: exp, ...(t.id_token ? { idToken: t.id_token } : {}) };
      writeBack(authFile, session.id, fresh);
      session = { ...onDisk, ...fresh };
      state.refreshes++;
    })();
    try { await refreshing; } finally { refreshing = null; }
  }

  async function post(body) {
    return doFetch(CODEX_API_URL, { method: 'POST', body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs), headers: {
      authorization: `Bearer ${session.accessToken}`, 'chatgpt-account-id': session.accountId, originator: 'codex_cli_rs',
      accept: 'text/event-stream', 'content-type': 'application/json' } });
  }

  // temperature / seed are accepted for interface compatibility and ignored (backend rejects temperature).
  async function chat(messages, { json = false, maxTokens = 8192 } = {}) {
    const { instructions, input } = toResponses(messages, { json });
    const body = { model, instructions, input, store: false, stream: true, max_output_tokens: maxTokens, ...(effort && effort !== 'none' ? { reasoning: { effort } } : {}), ...(json ? { text: { format: { type: 'json_object' } } } : {}) };
    let lastErr, authRetried = false;
    for (let a = 0; a <= retries; a++) {
      if (session.expiresAt - now() < PREEMPT_MS) await refresh(false);
      let res;
      try { res = await post(body); } catch (e) { lastErr = new Error(scrub(`chatgpt: network ${e?.name || ''} ${e?.message || ''}`)); await sleep(baseDelayMs * 2 ** a); continue; }
      const rl = {}; for (const [k, v] of res.headers || []) if (/^x-codex-(primary|secondary)-(used-percent|reset-after-seconds|window-minutes)$/.test(k)) rl[k.slice(8)] = Number(v);
      if (Object.keys(rl).length) state.rateLimits = rl;
      if (res.status === 401 && !authRetried) { authRetried = true; await refresh(true); a--; continue; }
      if (res.status === 429) {
        const t = await res.text().catch(() => '');
        const s = resetSeconds(t, now());
        const limit = /usage_limit|usage limit/i.test(t);
        if (s != null && s > maxWaitS) throw new Error(`chatgpt: subscription usage limit reached${limit ? ' (usage_limit_reached)' : ''}; window resets in ${Math.round(s)} s (${(s / 3600).toFixed(1)} h)`);
        lastErr = new Error(`chatgpt: HTTP 429${limit ? ' usage_limit_reached' : ''}`);
        if (a < retries) await sleep(s != null ? (s + 1) * 1000 : baseDelayMs * 2 ** a + Math.floor(Math.random() * 400));
        continue;
      }
      if (res.status >= 500) { lastErr = new Error(`chatgpt: HTTP ${res.status}`); await sleep(baseDelayMs * 2 ** a); continue; }
      if (!res.ok) throw new Error(`chatgpt: HTTP ${res.status}: ${scrub((await res.text().catch(() => '')).slice(0, 300))}`);
      let raw;
      try { raw = await res.text(); } catch (e) { lastErr = new Error(scrub(`chatgpt: stream read ${e?.name || ''} ${e?.message || ''}`)); await sleep(baseDelayMs * 2 ** a); continue; }
      try { return parseResponsesSSE(raw); } catch (e) {
        if (/ended before|server_error|overloaded|rate_limit/i.test(e.message) && !/invalid_request/i.test(e.message)) { lastErr = new Error(scrub(e.message)); await sleep(baseDelayMs * 2 ** a); continue; }
        throw new Error(scrub(e.message));
      }
    }
    throw lastErr || new Error('chatgpt: failed');
  }

  return { chat, model, state, get rateLimits() { return state.rateLimits; } };
}
