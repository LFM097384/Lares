// EmberBench · LLM providers. Every role (gate / attacker / judge / alt-judge / generator / checker) is a
// "provider:model" spec, configurable from the CLI. Keys come from env only and are never logged or written.
//   deepseek   → LARES_AI_LLM_KEY,  LARES_AI_LLM_BASE_URL (default https://api.deepseek.com)
//   dashscope  → DASHSCOPE_API_KEY, DASHSCOPE_BASE_URL    (default https://dashscope.aliyuncs.com/compatible-mode/v1)
// loadDashscopeKeyFile(csv) reads the Aliyun console CSV ("apiKey,<key>") into process.env at runtime.
import { readFileSync, existsSync } from 'node:fs';
import { createDeepSeekLLM, parseJSON } from '../core/gate/llm.mjs';

export const PROVIDERS = {
  deepseek: { family: 'deepseek', keyEnv: 'LARES_AI_LLM_KEY', baseEnv: 'LARES_AI_LLM_BASE_URL', base: 'https://api.deepseek.com' },
  dashscope: { family: 'qwen', keyEnv: 'DASHSCOPE_API_KEY', baseEnv: 'DASHSCOPE_BASE_URL', base: 'https://dashscope.aliyuncs.com/compatible-mode/v1' },
  mock: { family: 'mock', keyEnv: null, base: null },
};

// USD per 1M tokens. ASSUMPTIONS (list prices, 2026-10; verify before quoting):
//  deepseek-flash: api-docs.deepseek.com/quick_start/pricing — peak $0.30 in (cache miss) / $1.20 out (off-peak half). We use PEAK (upper bound).
//  qwen-*: Model Studio (China, Beijing) list prices converted at ¥7.1/$; qwen-max ¥2.4/¥9.6, qwen-plus ¥0.8/¥2, qwen-flash ¥0.15/¥1.5 per 1M.
export const PRICES = {
  'deepseek-flash': { in: 0.30, out: 1.20 },
  'deepseek-v4-pro': { in: 1.32, out: 3.96 },
  'qwen-max': { in: 0.34, out: 1.35 },
  'qwen-plus': { in: 0.11, out: 0.28 },
  'qwen-flash': { in: 0.021, out: 0.21 },
  'qwen3.7-plus': { in: 0.11, out: 0.28 },
  'qwen3.8-max': { in: 0.34, out: 1.35 },
  'kimi-k3': { in: 0.56, out: 2.25 }, // ASSUMPTION ¥4/¥16 per 1M (Kimi list price on DashScope); unverified
  mock: { in: 0, out: 0 },
};
export const priceOf = (model) => PRICES[model] || PRICES[String(model).replace(/-latest$/, '')] || { in: 1, out: 4, unknown: true };
export const costUSD = (model, u) => ((u.promptTokens || 0) * priceOf(model).in + (u.completionTokens || 0) * priceOf(model).out) / 1e6;

export function parseSpec(spec) {
  const s = String(spec || '');
  const i = s.indexOf(':');
  const provider = i < 0 ? s : s.slice(0, i);
  const model = i < 0 ? 'mock' : s.slice(i + 1);
  if (!PROVIDERS[provider]) throw new Error(`unknown provider "${provider}" (known: ${Object.keys(PROVIDERS).join(', ')})`);
  return { provider, model, family: familyOf(provider, model), spec: `${provider}:${model}` };
}
// model family (what matters for judge independence): DashScope also hosts deepseek / kimi / glm models.
export function familyOf(provider, model) {
  const m = String(model).toLowerCase();
  for (const f of ['deepseek', 'qwen', 'kimi', 'glm', 'minimax']) if (m.includes(f)) return f;
  return PROVIDERS[provider]?.family ?? provider;
}

export function loadDashscopeKeyFile(file) {
  if (!file || !existsSync(file)) return false;
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*apiKey\s*,\s*(\S+)\s*$/);
    if (m) { process.env.DASHSCOPE_API_KEY = m[1]; return true; }
  }
  return false;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// usage meter shared by a role: { calls, promptTokens, completionTokens, ms, errors }
export const newMeter = () => ({ calls: 0, promptTokens: 0, completionTokens: 0, ms: 0, errors: 0 });

function openAICompat({ base, key, model, timeoutMs = 300000, retries = 4, extraBody = {}, jsonMode = true }) {
  const scrub = (s) => String(s ?? '').split(key).join('***');
  return async function chat(messages, { json = false, temperature = 0, maxTokens = 4096 } = {}) {
    const body = { model, messages, max_tokens: maxTokens, ...extraBody };
    if (!/^kimi/.test(model)) body.temperature = temperature; // kimi-k3 on DashScope rejects non-default temperature
    if (json && jsonMode) body.response_format = { type: 'json_object' };
    let lastErr;
    for (let a = 0; a <= retries; a++) {
      if (a) await sleep(1500 * 2 ** (a - 1) + Math.floor(Math.random() * 400));
      let res;
      try {
        res = await fetch(`${base}/chat/completions`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
      } catch (e) { lastErr = new Error(scrub(`network: ${e?.name} ${e?.message}`)); continue; }
      if (res.status === 429 || res.status >= 500) { lastErr = new Error(`HTTP ${res.status}`); continue; }
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${scrub((await res.text().catch(() => '')).slice(0, 300))}`);
      let data; try { data = await res.json(); } catch { lastErr = new Error('non-JSON body'); continue; }
      const c = data?.choices?.[0];
      return { text: c?.message?.content ?? '', usage: data?.usage || {}, finish: c?.finish_reason };
    }
    throw lastErr || new Error('LLM failed');
  };
}

/**
 * makeLLM(spec, { meter, mockHandler }) → { chat(messages, opts) → {text, usage, finish}, model, family, spec, meter }
 * Every call is metered (tokens + wall ms). mock: mockHandler(messages, opts) → object|string.
 */
export function makeLLM(spec, { meter = newMeter(), mockHandler = null, timeoutMs } = {}) {
  const p = parseSpec(spec);
  let raw;
  if (p.provider === 'mock') {
    raw = async (messages, opts) => {
      const out = mockHandler ? await mockHandler(messages, opts) : {};
      return { text: typeof out === 'string' ? out : JSON.stringify(out), usage: {}, finish: 'stop' };
    };
  } else {
    const P = PROVIDERS[p.provider];
    const key = process.env[P.keyEnv];
    if (!key) throw new Error(`${p.spec}: env ${P.keyEnv} not set`);
    const base = String(process.env[P.baseEnv] || P.base).replace(/\/+$/, '');
    if (p.provider === 'deepseek') {
      const d = createDeepSeekLLM({ baseUrl: base, key, model: p.model, ...(timeoutMs ? { timeoutMs } : {}) });
      raw = (m, o) => d.chat(m, o);
    } else {
      raw = openAICompat({ base, key, model: p.model, ...(timeoutMs ? { timeoutMs } : {}), jsonMode: p.family === 'qwen', extraBody: /^(qwen3|kimi|deepseek)/.test(p.model) ? { enable_thinking: false } : {} });
    }
  }
  async function chat(messages, opts = {}) {
    const t0 = Date.now();
    try {
      const r = await raw(messages, opts);
      meter.calls++;
      meter.promptTokens += Number(r.usage?.prompt_tokens) || 0;
      meter.completionTokens += Number(r.usage?.completion_tokens) || 0;
      return r;
    } catch (e) { meter.errors++; throw e; } finally { meter.ms += Date.now() - t0; }
  }
  return { chat, model: p.model, family: p.family, spec: p.spec, provider: p.provider, meter };
}

/** chat + JSON parse, one retry on unparseable output. */
export async function askJSON(llm, system, user, { temperature = 0, maxTokens = 4096 } = {}) {
  let last;
  for (let k = 0; k < 2; k++) {
    const r = await llm.chat([{ role: 'system', content: system }, { role: 'user', content: typeof user === 'string' ? user : JSON.stringify(user) }], { json: true, temperature, maxTokens });
    try { return parseJSON(r.text); } catch (e) { last = new Error(`${e.message} (finish=${r.finish})`); }
  }
  throw last;
}
